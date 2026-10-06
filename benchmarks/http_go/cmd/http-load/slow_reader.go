package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"syscall"
	"time"
)

type readerSocketInfo struct {
	Local     string `json:"local_addr"`
	Remote    string `json:"remote_addr"`
	Requested int    `json:"receive_buffer_requested"`
	Effective int    `json:"receive_buffer_effective"`
}

func configureReaderSocket(conn *net.TCPConn) (readerSocketInfo, error) {
	info := readerSocketInfo{Local: conn.LocalAddr().String(), Remote: conn.RemoteAddr().String(), Requested: 65536}
	if err := conn.SetReadBuffer(info.Requested); err != nil {
		return info, err
	}
	raw, err := conn.SyscallConn()
	if err != nil {
		return info, err
	}
	var queryErr error
	err = raw.Control(func(fd uintptr) {
		info.Effective, queryErr = syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
	})
	if err != nil {
		return info, err
	}
	return info, queryErr
}

func (g *slowSockets) readerWriteBatch(s *slowSocket, c config) error {
	u, _ := url.Parse(c.URL)
	for ordinal := 0; ordinal < 8; ordinal++ {
		prefix := fmt.Sprintf("POST /echo HTTP/1.1\r\nHost: %s\r\nContent-Length: 1048576\r\n\r\n", u.Host)
		if err := g.write(s, c, []byte(prefix), false); err != nil {
			return err
		}
		if err := g.write(s, c, []byte{byte('b' + ordinal)}, false); err != nil {
			return err
		}
		for off := 1; off < len(g.readerPayload); off += 65536 {
			end := min(off+65536, len(g.readerPayload))
			if err := g.write(s, c, g.readerPayload[off:end], false); err != nil {
				return err
			}
		}
		g.mu.Lock()
		g.stats.ReaderWritesTotal++
		g.mu.Unlock()
	}
	return nil
}

func (g *slowSockets) readerReadDeadline(s *slowSocket, ioBudget time.Duration) error {
	deadline := time.Now().Add(ioBudget)
	if s.batchEnd.Before(deadline) {
		deadline = s.batchEnd
	}
	return s.SetReadDeadline(deadline)
}

func (g *slowSockets) readerReadBody(s *slowSocket, response *http.Response, ordinal int, buffer []byte, c config, begin time.Time) error {
	end := begin
	defer func() { g.overlap(s, begin, end) }()
	for quantum := 0; quantum < 16; quantum++ {
		planned := begin.Add(time.Duration(quantum+1) * c.SlowInterval)
		paced := g.ctx.Err() == nil
		if paced {
			wake := planned
			if s.batchEnd.Before(wake) {
				wake = s.batchEnd
			}
			timer := time.NewTimer(time.Until(wake))
			select {
			case <-timer.C:
			case <-g.ctx.Done():
			}
			timer.Stop()
			paced = g.ctx.Err() == nil
		}
		if !time.Now().Before(s.batchEnd) {
			end = time.Now()
			return os.ErrDeadlineExceeded
		}
		if err := g.readerReadDeadline(s, c.Timeout); err != nil {
			end = time.Now()
			return err
		}
		n, err := io.ReadFull(response.Body, buffer)
		at := time.Now()
		end = at
		g.mu.Lock()
		g.stats.ReaderReadTotal += uint64(n)
		g.mu.Unlock()
		g.visit(s, at, func(w *slowWindow, a *slowActivity) {
			a.ReadBytes += uint64(n)
			if paced {
				a.PacedReadBytes += uint64(n)
				if err == nil {
					a.ReadQuanta++
				}
				lag := int64(at.Sub(planned))
				if lag > a.TickLagMaxNS {
					a.TickLagMaxNS = lag
				}
				if w == g.stats.Measured {
					s.measuredDripBytes += uint64(n)
				}
			}
		})
		if err != nil {
			return err
		}
		if quantum == 0 {
			if buffer[0] != byte('b'+ordinal) || !bytes.Equal(buffer[1:], g.readerPayload[1:65536]) {
				return errors.New("reader response marker/order/body differs")
			}
		} else if !bytes.Equal(buffer, g.readerPayload[:65536]) {
			return errors.New("reader response body differs")
		}
	}
	return nil
}

func (g *slowSockets) readerCycle(s *slowSocket, c config, ready chan error, first bool, ioBudget time.Duration) (err error) {
	c.Timeout = ioBudget
	s.batchEnd = time.Now().Add(c.SetupTimeout)
	joined := make(chan error, 1)
	go func() {
		writeErr := g.readerWriteBatch(s, c)
		if writeErr != nil {
			s.Close()
		}
		joined <- writeErr
	}()
	defer func() {
		if err != nil {
			s.Close()
		}
		writeErr := <-joined
		if err == nil {
			err = writeErr
		}
		if err == nil {
			at := time.Now()
			g.mu.Lock()
			g.stats.TotalCycles++
			g.mu.Unlock()
			g.visit(s, at, func(_ *slowWindow, a *slowActivity) { a.ValidatedCycles++ })
		}
	}()
	req := &http.Request{Method: "POST"}
	buffer := make([]byte, 65536)
	for ordinal := 0; ordinal < 8; ordinal++ {
		var response *http.Response
		err = g.readerReadDeadline(s, ioBudget)
		if err == nil {
			response, err = http.ReadResponse(s.reader, req)
		}
		if err == nil && (response.Proto != "HTTP/1.1" || response.StatusCode != 200 || response.ContentLength != 1048576 || response.Header.Get("Content-Length") == "" || response.Close) {
			err = errors.New("reader requires strict original-socket HTTP/1.1 200 with 1MiB Content-Length")
		}
		begin := time.Now()
		if first && ordinal == 0 {
			ready <- err
		}
		if err != nil {
			s.Close()
			if response != nil {
				response.Body.Close()
			}
			return err
		}
		err = g.readerReadBody(s, response, ordinal, buffer, c, begin)
		if err != nil {
			s.Close()
		}
		response.Body.Close()
		if err != nil {
			return err
		}
		at := time.Now()
		g.mu.Lock()
		g.stats.ReaderResponsesTotal++
		g.mu.Unlock()
		g.visit(s, at, func(_ *slowWindow, a *slowActivity) { a.ValidatedResponses++; a.ValidatedPayloadBytes += 1048576 })
	}
	return nil
}
