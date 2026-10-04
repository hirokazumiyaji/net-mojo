package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func readerConfig(url string) config {
	c := slowConfig(url)
	c.SlowHeaders, c.SlowBodies, c.SlowReaders = 0, 0, 1
	c.Warmup, c.Duration, c.SlowInterval = 30*time.Millisecond, 100*time.Millisecond, time.Millisecond
	return c
}

func TestSlowReaderEightMarkedEchoesOriginalSocketAndOrdinaryWindows(t *testing.T) {
	for _, rate := range []int{0, 200} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			var mu sync.Mutex
			requests, probes := map[string]int{}, map[string]int{}
			var ordinary atomic.Int64
			var bad atomic.Bool
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/fixed" {
					mu.Lock()
					probes[r.RemoteAddr]++
					mu.Unlock()
					ordinary.Add(1)
					io.WriteString(w, string(bytes.Repeat([]byte("a"), 64)))
					return
				}
				body, err := io.ReadAll(r.Body)
				mu.Lock()
				ordinal := requests[r.RemoteAddr] % 8
				requests[r.RemoteAddr]++
				mu.Unlock()
				if err != nil || r.ContentLength != 1<<20 || r.Header.Get("Expect") != "" || len(body) != 1<<20 || body[0] != byte('b'+ordinal) || !bytes.Equal(body[1:], bytes.Repeat([]byte("b"), (1<<20)-1)) {
					bad.Store(true)
				}
				w.Header().Set("Content-Length", fmt.Sprint(len(body)))
				w.Write(body)
			}))
			defer s.Close()
			c := readerConfig(s.URL + "/fixed")
			c.Rate = rate
			r, err := run(c)
			if err != nil || !r.Valid || r.Slow == nil || r.Slow.Readers.Requested != 1 || r.Slow.Readers.Initial != 1 || r.Slow.Readers.Final != 1 || r.Slow.Readers.Closed != 1 || r.Slow.Readers.MeasuredUsed != 1 || bad.Load() || ordinary.Load() == 0 {
				t.Fatalf("real mixed reader lifecycle absent: result=%+v slow=%+v bad=%v err=%v", r, r.Slow, bad.Load(), err)
			}
			if len(r.Slow.ReaderBuffers) != 1 || r.Slow.ReaderBuffers[0].Requested != 65536 || r.Slow.ReaderBuffers[0].Effective <= 0 || r.Slow.ReaderBuffers[0].Remote != s.Listener.Addr().String() || r.Slow.ReaderPressure != "unverified" {
				t.Fatalf("actual original socket buffer/pressure metadata absent: %+v", r.Slow)
			}
			mu.Lock()
			if requests[r.Slow.ReaderBuffers[0].Local] == 0 {
				t.Error("metadata tuple is not original echo peer")
			}
			validPeer := len(requests) == 1
			for address, count := range requests {
				validPeer = validPeer && count >= 8 && count%8 == 0 && probes[address] == 2
			}
			mu.Unlock()
			if !validPeer {
				t.Fatal("reader did not preserve exactly one original socket/eight marked responses/pre-postflight")
			}
			for _, pair := range []struct {
				ordinary *phaseWindow
				slow     *slowWindow
			}{{r.WarmupWindow, r.Slow.Warmup}, {r.MeasurementWindow, r.Slow.Measured}} {
				if pair.slow == nil || *pair.slow.Window != *pair.ordinary || pair.slow.Readers.ReadQuanta == 0 || pair.slow.Readers.PacedReadBytes == 0 || pair.slow.Readers.IncompleteNS == 0 {
					t.Fatalf("actual ordinary/read/known-unread windows absent: %+v", pair.slow)
				}
			}
			if r.Started != r.Success+r.Errors+r.Cutoff || r.Samples != r.Success || r.ResponseBytes != r.Success*64 {
				t.Fatal("ordinary accounting changed")
			}
		})
	}
}

type blockedWrite struct {
	size, sendBuffer int
	remote           string
}
type pressureListener struct {
	net.Listener
	once     sync.Once
	entered  chan blockedWrite
	finished chan struct{}
}
type pressureConn struct {
	net.Conn
	owner      *pressureListener
	sendBuffer int
}

func (l *pressureListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tcp := conn.(*net.TCPConn)
	if err = tcp.SetWriteBuffer(16384); err != nil {
		tcp.Close()
		return nil, err
	}
	raw, err := tcp.SyscallConn()
	if err != nil {
		tcp.Close()
		return nil, err
	}
	var effective int
	var queryErr error
	err = raw.Control(func(fd uintptr) {
		effective, queryErr = syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_SNDBUF)
	})
	if err != nil {
		tcp.Close()
		return nil, err
	}
	if queryErr != nil {
		tcp.Close()
		return nil, queryErr
	}
	return &pressureConn{Conn: tcp, owner: l, sendBuffer: effective}, nil
}
func (c *pressureConn) Write(p []byte) (int, error) {
	tracked := false
	if len(p) >= 65536 {
		c.owner.once.Do(func() { tracked = true; c.owner.entered <- blockedWrite{len(p), c.sendBuffer, c.RemoteAddr().String()} })
	}
	n, err := c.Conn.Write(p)
	if tracked {
		c.owner.finished <- struct{}{}
	}
	return n, err
}

func TestSlowReaderActualServerWriteBlocksUntilReadCreditWhileSiblingProgresses(t *testing.T) {
	s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fixed" {
			io.WriteString(w, string(bytes.Repeat([]byte("a"), 64)))
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	}))
	listener := &pressureListener{Listener: s.Listener, entered: make(chan blockedWrite, 1), finished: make(chan struct{}, 1)}
	s.Listener = listener
	s.Start()
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.SlowInterval = 20 * time.Millisecond
	c.SetupTimeout = 5 * time.Second
	w, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	g := &slowSockets{stats: &slowStats{Readers: slowCohort{Requested: 1}}}
	defer g.close()
	if err := g.setup(c, w); err != nil {
		t.Fatal(err)
	}
	g.observe(time.Second, true)
	var write blockedWrite
	select {
	case write = <-listener.entered:
	case <-time.After(time.Second):
		t.Fatal("actual server never entered large Write")
	}
	transport := &http.Transport{}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: time.Second}
	for i := 0; i < 5; i++ {
		if err := request(context.Background(), client, c, w); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(time.Second)
	var paced uint64
	for time.Now().Before(deadline) {
		g.mu.Lock()
		paced = g.stats.Measured.Readers.PacedReadBytes
		g.mu.Unlock()
		if paced > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if paced == 0 || write.size < 65536 || write.sendBuffer <= 0 {
		t.Fatalf("pressure/read-credit evidence absent: write=%+v paced=%d", write, paced)
	}
	select {
	case <-listener.finished:
		t.Fatal("large server Write already returned before credit release")
	default:
	}
	g.cancel()
	if err := g.finish(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-listener.finished:
	case <-time.After(time.Second):
		t.Fatal("same blocked server Write did not resume after drain credit")
	}
	if g.stats.ReaderReadTotal != 8<<20 || g.stats.ReaderResponsesTotal != 8 || g.stats.ReaderWritesTotal != 8 || g.stats.Readers.Final != 1 {
		t.Fatalf("writer/reader batch did not finish/join exactly: %+v", g.stats)
	}
	t.Logf("causal TCP pressure: remote=%s serverWrite=%d SO_SNDBUF=%d pacedBeforeRelease=%d ordinaryExact=5 drained=%d", write.remote, write.size, write.sendBuffer, paced, g.stats.ReaderReadTotal)
}

func TestSlowReaderConfigurationAndFiniteBatchCap(t *testing.T) {
	for _, change := range []func(*config){
		func(c *config) { c.SlowReaders = -1 }, func(c *config) { c.SlowReaders = math.MaxInt }, func(c *config) { c.SlowInterval = 30 * time.Second / 16 }, func(c *config) { c.KeepAlive = false }, func(c *config) { c.SetupTimeout = 0 }, func(c *config) { c.IdleConnections = 1 },
	} {
		c := readerConfig("http://localhost/fixed")
		change(&c)
		if _, err := prepare(c); err == nil {
			t.Fatalf("invalid reader config accepted: %+v", c)
		}
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fixed" {
			io.WriteString(w, string(bytes.Repeat([]byte("a"), 64)))
			return
		}
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			panic(err)
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(time.Second))
		io.Copy(io.Discard, conn)
	}))
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.SetupTimeout = 30 * time.Millisecond
	begin := time.Now()
	r, err := run(c)
	if err == nil || r.Valid || r.Slow.Readers.Initial != 1 || r.Slow.Readers.Closed != 1 || r.Slow.Readers.Final != 0 || r.Started != 0 || time.Since(begin) > time.Second {
		t.Fatalf("finite cap/blocked writer/withheld response escaped cleanup: %+v slow=%+v err=%v", r, r.Slow, err)
	}
}

func TestSlowReaderMalformedOrderTruncationAndPostflightCloseAndJoin(t *testing.T) {
	for _, failure := range []string{"status", "length", "close", "marker", "truncated", "postflight"} {
		t.Run(failure, func(t *testing.T) {
			var mu sync.Mutex
			first := ""
			probes := 0
			ordinal := 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/fixed" {
					mu.Lock()
					if first == "" {
						first = r.RemoteAddr
					}
					if r.RemoteAddr == first {
						probes++
					}
					wrong := failure == "postflight" && r.RemoteAddr == first && probes == 2
					mu.Unlock()
					body := strings.Repeat("a", 64)
					if wrong {
						body = strings.Repeat("z", 64)
					}
					io.WriteString(w, body)
					return
				}
				body, err := io.ReadAll(r.Body)
				if err != nil {
					return
				}
				mu.Lock()
				i := ordinal
				ordinal++
				mu.Unlock()
				if failure == "truncated" {
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						panic(err)
					}
					defer conn.Close()
					fmt.Fprint(conn, "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n")
					conn.Write(body[:65536])
					return
				}
				w.Header().Set("Content-Length", fmt.Sprint(len(body)))
				switch failure {
				case "status":
					w.WriteHeader(503)
				case "length":
					w.Header().Set("Content-Length", "0")
					body = nil
				case "close":
					w.Header().Set("Connection", "close")
				case "marker":
					if i == 1 {
						body[0] = 'z'
					}
				}
				w.Write(body)
			}))
			defer s.Close()
			c := readerConfig(s.URL + "/fixed")
			c.Warmup = 0
			begin := time.Now()
			r, err := run(c)
			if err == nil || r.Valid || r.Slow.Readers.Closed != 1 || r.Slow.Readers.Final != 0 || time.Since(begin) > 2*time.Second {
				t.Fatalf("bad reader peer accepted or unjoined: result=%+v slow=%+v err=%v", r, r.Slow, err)
			}
			if failure == "postflight" && (r.Slow.ReaderResponsesTotal != 8 || r.Slow.ReaderWritesTotal != 8) {
				t.Fatal("postflight fixture did not finish the real eight-response batch")
			}
		})
	}
}

func TestSlowReaderBlockedUploadAndResponseUnblockAtFiniteCap(t *testing.T) {
	release, joined := make(chan struct{}), make(chan struct{})
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fixed" {
			io.WriteString(w, strings.Repeat("a", 64))
			return
		}
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			panic(err)
		}
		defer close(joined)
		defer conn.Close()
		if err := conn.(*net.TCPConn).SetReadBuffer(16384); err != nil {
			panic(err)
		}
		fmt.Fprint(conn, "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n")
		<-release
	}))
	defer s.Close()
	defer func() {
		close(release)
		select {
		case <-joined:
		case <-time.After(time.Second):
			t.Error("owned withheld peer did not join")
		}
	}()
	c := readerConfig(s.URL + "/fixed")
	c.Warmup = 0
	c.Duration = 20 * time.Millisecond
	c.SetupTimeout = 50 * time.Millisecond
	begin := time.Now()
	r, err := run(c)
	if err == nil || r.Valid || r.Success == 0 || r.Slow.ReaderWritesTotal >= 8 || r.Slow.Readers.Final != 0 || r.Slow.Readers.Closed != 1 || time.Since(begin) > time.Second {
		t.Fatalf("blocked uploader/read join escaped cap: result=%+v slow=%+v err=%v", r, r.Slow, err)
	}
	t.Logf("finite-cap blocked directions: ordinary=%d acceptedFullUploads=%d of8 readerBytes=%d elapsed=%s", r.Success, r.Slow.ReaderWritesTotal, r.Slow.ReaderReadTotal, time.Since(begin))
}

func TestSlowReaderPartialSetupClosesOriginalSocketAndMetadata(t *testing.T) {
	var s *httptest.Server
	s = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		s.Listener.Close()
		io.WriteString(w, strings.Repeat("a", 64))
	}))
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.SlowReaders = 2
	r, err := run(c)
	if err == nil || r.Started != 0 || r.Slow.Readers.Requested != 2 || r.Slow.Readers.Initial != 1 || r.Slow.Readers.Closed != 1 || len(r.Slow.ReaderBuffers) != 1 {
		t.Fatalf("partial reader setup was hidden/unowned: %+v slow=%+v err=%v", r, r.Slow, err)
	}
}

func TestSlowReaderNoPacedReadAndOrdinaryOverloadCannotClaimValid(t *testing.T) {
	var delay atomic.Bool
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/echo" {
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.Write(body)
			return
		}
		if delay.Load() {
			time.Sleep(15 * time.Millisecond)
		}
		io.WriteString(w, strings.Repeat("a", 64))
	}))
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.Warmup = 0
	c.Duration = 20 * time.Millisecond
	c.SlowInterval = 250 * time.Millisecond
	r, err := run(c)
	if err == nil || r.Valid || r.Success == 0 || r.Slow.Readers.MeasuredUsed != 0 || r.Slow.Readers.Final != 1 || r.Slow.ReaderReadTotal != 8<<20 || r.Slow.Measured.Readers.PacedReadBytes != 0 || r.Slow.Measured.Readers.IncompleteNS == 0 {
		t.Fatalf("unread/prefetch/upload qualified as paced read: result=%+v slow=%+v err=%v", r, r.Slow, err)
	}
	delay.Store(true)
	c.Connections, c.Rate, c.Duration, c.SlowInterval = 1, 1000, 90*time.Millisecond, time.Millisecond
	r, err = run(c)
	if err == nil || r.Valid || r.Arrivals.Dropped == 0 || r.Slow.Readers.Final != 1 || r.Started != r.Success+r.Errors+r.Cutoff || r.Arrivals.Scheduled != r.Started+r.Arrivals.Dropped+r.Arrivals.Unstarted {
		t.Fatalf("reader hid ordinary overload: result=%+v slow=%+v err=%v", r, r.Slow, err)
	}
}

func TestSlowReaderFreshIOBudgetAllowsLongerFiniteBatch(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fixed" {
			io.WriteString(w, strings.Repeat("a", 64))
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	}))
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.SetupTimeout = 2 * time.Second
	w, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", s.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := configureReaderSocket(conn.(*net.TCPConn)); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	g := &slowSockets{stats: &slowStats{Readers: slowCohort{Requested: 1}}, readerPayload: bytes.Repeat([]byte("b"), 1<<20)}
	g.ctx, g.cancel = context.WithCancel(context.Background())
	slot := &slowSocket{heldSocket: heldSocket{conn, bufio.NewReader(conn)}, isReader: true, cohort: &g.stats.Readers}
	g.sockets = []*slowSocket{slot}
	defer g.close()
	if err := slot.probe(g.ctx, c, w); err != nil {
		t.Fatal(err)
	}
	g.observe(2*time.Second, true)
	begin := time.Now()
	ready := make(chan error, 1)
	if err := g.readerCycle(slot, c, ready, true, 30*time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if err := <-ready; err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(begin); elapsed <= 30*time.Millisecond || elapsed >= 2*time.Second || g.stats.ReaderResponsesTotal != 8 || g.stats.ReaderWritesTotal != 8 {
		t.Fatalf("fresh operation budget became aggregate or lost batch: elapsed=%s stats=%+v", elapsed, g.stats)
	}
	if err := slot.probe(g.ctx, c, w); err != nil {
		t.Fatal(err)
	}
}

func TestSlowReaderFiniteBatchCapInterruptsPacingWait(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fixed" {
			io.WriteString(w, strings.Repeat("a", 64))
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body)
	}))
	defer s.Close()
	c := readerConfig(s.URL + "/fixed")
	c.SetupTimeout, c.SlowInterval = 50*time.Millisecond, time.Second
	w, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", s.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := configureReaderSocket(conn.(*net.TCPConn)); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	g := &slowSockets{stats: &slowStats{Readers: slowCohort{Requested: 1}}, readerPayload: bytes.Repeat([]byte("b"), 1<<20)}
	g.ctx, g.cancel = context.WithCancel(context.Background())
	slot := &slowSocket{heldSocket: heldSocket{conn, bufio.NewReader(conn)}, isReader: true, cohort: &g.stats.Readers}
	g.sockets = []*slowSocket{slot}
	defer g.close()
	if err := slot.probe(g.ctx, c, w); err != nil {
		t.Fatal(err)
	}
	ready := make(chan error, 1)
	begin := time.Now()
	err = g.readerCycle(slot, c, ready, true, 30*time.Second)
	elapsed := time.Since(begin)
	if initialErr := <-ready; initialErr != nil {
		t.Fatalf("response header did not arrive before pacing: %v", initialErr)
	}
	if err == nil || elapsed > 500*time.Millisecond || g.stats.ReaderResponsesTotal != 0 || g.stats.ReaderReadTotal != 0 {
		t.Fatalf("batch cap failed to interrupt pacing and join writer: elapsed=%s err=%v stats=%+v", elapsed, err, g.stats)
	}
	t.Logf("50 ms finite cap interrupted 1 s pacing tick and joined writer in %s", elapsed)
}
