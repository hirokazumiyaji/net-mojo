package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sync"
	"syscall"
	"time"
)

type slowActivity struct {
	ValidatedResponses    uint64 `json:"validated_responses,omitempty"`
	ReadBytes             uint64 `json:"response_bytes_read,omitempty"`
	PacedReadBytes        uint64 `json:"paced_response_bytes_read,omitempty"`
	ReadQuanta            uint64 `json:"paced_read_quanta,omitempty"`
	IncompleteNS          int64  `json:"incomplete_ns"`
	DripBytes             uint64 `json:"drip_bytes_written"`
	WrittenBytes          uint64 `json:"request_bytes_written"`
	ValidatedCycles       uint64 `json:"validated_cycles"`
	ValidatedPayloadBytes uint64 `json:"validated_response_payload_bytes"`
	TickLagMaxNS          int64  `json:"tick_lag_max_ns"`
}

type slowWindow struct {
	Window     *phaseWindow `json:"window"`
	Readers    slowActivity `json:"readers"`
	Headers    slowActivity `json:"headers"`
	Bodies     slowActivity `json:"bodies"`
	begin, end time.Time
}

type slowCohort struct {
	Requested    int `json:"requested"`
	Initial      int `json:"confirmed_initial"`
	Final        int `json:"confirmed_final"`
	Closed       int `json:"closed_owned"`
	MeasuredUsed int `json:"used_in_measurement"`
}

type slowStats struct {
	ReaderBatchRequests  int                `json:"reader_batch_requests"`
	ReaderBodyBytes      int                `json:"reader_body_bytes"`
	ReaderChunkBytes     int                `json:"reader_chunk_bytes"`
	ReaderIOBudgetNS     int64              `json:"reader_io_budget_ns"`
	ReaderBatchCapNS     int64              `json:"reader_batch_cap_ns"`
	ReaderPressure       string             `json:"reader_server_send_pressure"`
	ReaderBuffers        []readerSocketInfo `json:"reader_sockets,omitempty"`
	ReaderReadTotal      uint64             `json:"reader_response_bytes_read_total"`
	ReaderResponsesTotal uint64             `json:"reader_validated_responses_total"`
	ReaderWritesTotal    uint64             `json:"reader_request_bodies_written_total"`
	HeaderTicks          int                `json:"header_ticks"`
	BodyBytes            int                `json:"body_bytes"`
	BodyChunkBytes       int                `json:"body_chunk_bytes"`
	Readers              slowCohort         `json:"readers"`
	Headers              slowCohort         `json:"headers"`
	Bodies               slowCohort         `json:"bodies"`
	FDSoft               uint64             `json:"loader_fd_limit_soft"`
	FDHard               uint64             `json:"loader_fd_limit_hard"`
	TotalWritten         uint64             `json:"profile_request_bytes_written_total"`
	TotalCycles          uint64             `json:"validated_profile_cycles_total"`
	SetupSeconds         float64            `json:"setup_seconds"`
	PostflightSeconds    float64            `json:"postflight_seconds"`
	Warmup               *slowWindow        `json:"warmup,omitempty"`
	Measured             *slowWindow        `json:"measurement,omitempty"`
	Error                string             `json:"first_profile_error,omitempty"`
}

type slowSocket struct {
	heldSocket
	body              bool
	isReader          bool
	batchEnd          time.Time
	cohort            *slowCohort
	measuredDripBytes uint64
	measuredOverlap   int64
}

type slowSockets struct {
	mu            sync.Mutex
	stats         *slowStats
	sockets       []*slowSocket
	ctx           context.Context
	cancel        context.CancelFunc
	workers       sync.WaitGroup
	readerPayload []byte
}

func (g *slowSockets) setup(c config, w workload) error {
	start := time.Now()
	defer func() { g.stats.SetupSeconds = time.Since(start).Seconds() }()
	g.ctx, g.cancel = context.WithCancel(context.Background())
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		return err
	}
	g.stats.FDSoft, g.stats.FDHard = limit.Cur, limit.Max
	if uint64(c.Connections+c.SlowHeaders+c.SlowBodies+c.SlowReaders) > limit.Cur {
		return errors.New("requested sockets exceed loader FD limit")
	}
	ctx, cancel := context.WithTimeout(g.ctx, c.SetupTimeout)
	defer cancel()
	u, _ := url.Parse(c.URL)
	port := u.Port()
	if port == "" {
		port = "80"
	}
	dialer := net.Dialer{Timeout: c.Timeout}
	if c.SlowReaders > 0 {
		g.readerPayload = bytes.Repeat([]byte("b"), 1<<20)
	}
	for i := 0; i < c.SlowHeaders+c.SlowBodies+c.SlowReaders; i++ {
		conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))
		if err != nil {
			return err
		}
		s := &slowSocket{heldSocket: heldSocket{conn, bufio.NewReader(conn)}, body: i >= c.SlowHeaders && i < c.SlowHeaders+c.SlowBodies, isReader: i >= c.SlowHeaders+c.SlowBodies}
		s.cohort = &g.stats.Headers
		if s.body {
			s.cohort = &g.stats.Bodies
		}
		if s.isReader {
			s.cohort = &g.stats.Readers
		}
		g.sockets = append(g.sockets, s)
		if s.isReader {
			info, err := configureReaderSocket(conn.(*net.TCPConn))
			if err != nil {
				return err
			}
			g.stats.ReaderBuffers = append(g.stats.ReaderBuffers, info)
		}
		if err := s.probe(ctx, c, w); err != nil {
			return err
		}
		s.cohort.Initial++
	}
	ready := make(chan error, len(g.sockets))
	g.workers.Add(len(g.sockets))
	for _, s := range g.sockets {
		go g.worker(s, c, w, ready)
	}
	for range g.sockets {
		if err := <-ready; err != nil {
			return err
		}
	}
	return nil
}

func (g *slowSockets) observe(duration time.Duration, measured bool) (time.Time, time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	begin := time.Now()
	end := begin.Add(duration)
	w := &slowWindow{Window: newPhaseWindow(begin, end), begin: begin, end: end}
	if measured {
		g.stats.Measured = w
	} else {
		g.stats.Warmup = w
	}
	return begin, end
}

func (g *slowSockets) visit(s *slowSocket, at time.Time, fn func(*slowWindow, *slowActivity)) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, w := range []*slowWindow{g.stats.Warmup, g.stats.Measured} {
		if w != nil && !at.Before(w.begin) && at.Before(w.end) {
			a := &w.Headers
			if s.body {
				a = &w.Bodies
			} else if s.isReader {
				a = &w.Readers
			}
			fn(w, a)
		}
	}
}

func (g *slowSockets) overlap(s *slowSocket, begin, end time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, w := range []*slowWindow{g.stats.Warmup, g.stats.Measured} {
		if w == nil {
			continue
		}
		first, last := begin, end
		if first.Before(w.begin) {
			first = w.begin
		}
		if last.After(w.end) {
			last = w.end
		}
		if !first.Before(last) {
			continue
		}
		a := &w.Headers
		if s.body {
			a = &w.Bodies
		} else if s.isReader {
			a = &w.Readers
		}
		ns := int64(last.Sub(first))
		a.IncompleteNS += ns
		if w == g.stats.Measured {
			s.measuredOverlap += ns
		}
	}
}

func (g *slowSockets) write(s *slowSocket, c config, data []byte, drip bool) error {
	deadline := time.Now().Add(c.Timeout)
	if s.isReader && s.batchEnd.Before(deadline) {
		deadline = s.batchEnd
	}
	if err := s.SetWriteDeadline(deadline); err != nil {
		return err
	}
	n, err := s.Write(data)
	at := time.Now()
	g.mu.Lock()
	g.stats.TotalWritten += uint64(n)
	g.mu.Unlock()
	g.visit(s, at, func(w *slowWindow, a *slowActivity) {
		a.WrittenBytes += uint64(n)
		if drip {
			a.DripBytes += uint64(n)
			if w == g.stats.Measured {
				s.measuredDripBytes += uint64(n)
			}
		}
	})
	return err
}

func (g *slowSockets) cycle(s *slowSocket, c config, payload []byte, ready chan error, first bool) error {
	u, _ := url.Parse(c.URL)
	req := &http.Request{Method: "GET"}
	prefix := fmt.Sprintf("GET /fixed HTTP/1.1\r\nHost: %s\r\nX-Slow: ", u.Host)
	ticks := 8
	if s.body {
		req.Method, ticks = "POST", 64
		prefix = fmt.Sprintf("POST /echo HTTP/1.1\r\nHost: %s\r\nContent-Length: 65536\r\nExpect: 100-continue\r\n\r\n", u.Host)
	}
	err := g.write(s, c, []byte(prefix), false)
	if err == nil && s.body {
		err = s.SetReadDeadline(time.Now().Add(c.Timeout))
		if err == nil {
			var interim *http.Response
			interim, err = http.ReadResponse(s.reader, req)
			if err == nil {
				interim.Body.Close()
				if interim.Proto != "HTTP/1.1" || interim.StatusCode != 100 || interim.Header.Get("Content-Length") != "" || len(interim.TransferEncoding) != 0 {
					err = errors.New("slow body requires strict HTTP/1.1 100 Continue")
				}
			}
		}
	}
	if first {
		ready <- err
	}
	if err != nil {
		return err
	}
	begin := time.Now()
	sent := 0
	for sent < ticks {
		planned := begin.Add(time.Duration(sent+1) * c.SlowInterval)
		timer := time.NewTimer(time.Until(planned))
		select {
		case <-timer.C:
		case <-g.ctx.Done():
		}
		timer.Stop()
		if g.ctx.Err() != nil {
			break
		}
		at := time.Now()
		lag := int64(at.Sub(planned))
		g.visit(s, at, func(_ *slowWindow, a *slowActivity) {
			if lag > a.TickLagMaxNS {
				a.TickLagMaxNS = lag
			}
		})
		data := []byte("a")
		if s.body {
			data = payload[sent*1024 : (sent+1)*1024]
		}
		err = g.write(s, c, data, true)
		if err != nil {
			break
		}
		sent++
	}
	if err == nil {
		data := []byte("\r\n\r\n")
		if s.body {
			data = payload[sent*1024:]
		}
		err = g.write(s, c, data, false)
	}
	g.overlap(s, begin, time.Now())
	if err != nil {
		return err
	}
	if err := s.SetReadDeadline(time.Now().Add(c.Timeout)); err != nil {
		return err
	}
	response, err := http.ReadResponse(s.reader, req)
	if err != nil {
		return err
	}
	if response.Close {
		response.Body.Close()
		return errors.New("slow response closes original socket")
	}
	expected := bytes.Repeat([]byte("a"), 64)
	if s.body {
		expected = payload
	}
	if err := validateResponse(response, workload{expected: expected}); err != nil {
		return err
	}
	at := time.Now()
	g.mu.Lock()
	g.stats.TotalCycles++
	g.mu.Unlock()
	g.visit(s, at, func(_ *slowWindow, a *slowActivity) {
		a.ValidatedCycles++
		a.ValidatedPayloadBytes += uint64(len(expected))
	})
	return nil
}

func (g *slowSockets) worker(s *slowSocket, c config, w workload, ready chan error) {
	defer g.workers.Done()
	var payload []byte
	if s.body {
		payload = bytes.Repeat([]byte("b"), 65536)
	}
	var err error
	for first := true; ; first = false {
		g.mu.Lock()
		ended := g.stats.Measured != nil && !time.Now().Before(g.stats.Measured.end)
		g.mu.Unlock()
		if ended {
			break
		}
		if s.isReader {
			err = g.readerCycle(s, c, ready, first, 30*time.Second)
		} else {
			err = g.cycle(s, c, payload, ready, first)
		}
		if err != nil || g.ctx.Err() != nil {
			break
		}
	}
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), c.SetupTimeout)
		defer cancel()
		err = s.probe(ctx, c, w)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if err != nil {
		if g.stats.Error == "" {
			g.stats.Error = err.Error()
		}
	} else {
		s.cohort.Final++
	}
}

func (g *slowSockets) finish() error {
	start := time.Now()
	g.cancel()
	g.workers.Wait()
	g.stats.PostflightSeconds = time.Since(start).Seconds()
	for _, s := range g.sockets {
		if s.measuredOverlap > 0 && s.measuredDripBytes > 0 {
			s.cohort.MeasuredUsed++
		}
	}
	if g.stats.Error != "" {
		return errors.New(g.stats.Error)
	}
	if g.stats.Headers.MeasuredUsed != g.stats.Headers.Requested || g.stats.Bodies.MeasuredUsed != g.stats.Bodies.Requested || g.stats.Readers.MeasuredUsed != g.stats.Readers.Requested {
		return errors.New("slow sockets lack measured incomplete-phase traffic")
	}
	return nil
}

func (g *slowSockets) close() {
	g.cancel()
	for _, s := range g.sockets {
		s.Close()
		s.cohort.Closed++
	}
	g.workers.Wait()
}
