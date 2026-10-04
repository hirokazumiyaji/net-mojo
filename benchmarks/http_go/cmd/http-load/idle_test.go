package main

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func idleConfig(url string) config {
	c := testConfig(url)
	c.Connections, c.IdleConnections = 2, 3
	c.Duration, c.SetupTimeout = 60*time.Millisecond, time.Second
	return c
}

func TestOriginalIdleSocketsStayIdleAndAllConnectionsClose(t *testing.T) {
	var mu sync.Mutex
	calls := map[string]int{}
	order := []string{}
	var closed atomic.Int64
	s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		if calls[r.RemoteAddr] == 0 {
			order = append(order, r.RemoteAddr)
		}
		calls[r.RemoteAddr]++
		mu.Unlock()
		fmt.Fprint(w, strings.Repeat("a", 64))
	}))
	s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateClosed {
			closed.Add(1)
		}
	}
	s.Start()
	defer s.Close()
	c := idleConfig(s.URL + "/fixed")
	c.Warmup = 20 * time.Millisecond
	r, err := run(c)
	if err != nil || !r.Valid || r.Idle.InitialIdle != 3 || r.Idle.FinalIdle != 3 || r.Idle.InitialActive != 2 || r.Idle.MeasuredActive != 2 || r.Idle.RequestedTotal != 5 || r.Idle.Replacements != 0 || r.Idle.EarlyActiveClosed != 0 || r.Idle.LoaderFDSoft == 0 || r.MeasurementWindow.ElapsedNS != int64(c.Duration) {
		t.Fatalf("original connection proof failed: %+v idle=%+v %v", r, r.Idle, err)
	}
	mu.Lock()
	if len(order) != 5 {
		t.Fatalf("used %d sockets instead of five", len(order))
	}
	for _, address := range order[:3] {
		if calls[address] != 2 {
			t.Fatalf("idle socket performed %d requests", calls[address])
		}
	}
	for _, address := range order[3:] {
		if calls[address] < 3 {
			t.Fatalf("active socket did not perform warmup and measurement: %d", calls[address])
		}
	}
	mu.Unlock()
	deadline := time.Now().Add(time.Second)
	for closed.Load() != 5 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if closed.Load() != 5 {
		t.Fatalf("leaked owned sockets: closed=%d", closed.Load())
	}
}

func TestIdleEOFAndWrongFinalBodyInvalidateSuccessfulMeasurement(t *testing.T) {
	for _, fail := range []string{"eof", "body"} {
		t.Run(fail, func(t *testing.T) {
			var mu sync.Mutex
			var first net.Conn
			var address string
			calls := map[string]int{}
			var once sync.Once
			var closed atomic.Int64
			s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				if address == "" {
					address = r.RemoteAddr
				}
				calls[r.RemoteAddr]++
				count, idle, original := calls[r.RemoteAddr], r.RemoteAddr == address, first
				mu.Unlock()
				if fail == "eof" && !idle && count == 2 {
					once.Do(func() { original.Close() })
				}
				body := strings.Repeat("a", 64)
				if fail == "body" && idle && count == 2 {
					body = strings.Repeat("z", 64)
				}
				fmt.Fprint(w, body)
			}))
			s.Config.ConnState = func(conn net.Conn, state http.ConnState) {
				if state == http.StateClosed {
					closed.Add(1)
				}
				if state == http.StateNew {
					mu.Lock()
					if first == nil {
						first = conn
					}
					mu.Unlock()
				}
			}
			s.Start()
			defer s.Close()
			r, err := run(idleConfig(s.URL + "/fixed"))
			if err == nil || r.Valid || r.Success == 0 || r.Idle.InitialIdle != 3 || r.Idle.FinalIdle != 0 {
				t.Fatalf("lost/invalid idle socket accepted: %+v idle=%+v %v", r, r.Idle, err)
			}
			deadline := time.Now().Add(time.Second)
			for closed.Load() != 5 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if closed.Load() != 5 {
				t.Fatalf("postflight failure leaked sockets: %d", closed.Load())
			}
		})
	}
}

func TestUnderfedArrivalsCannotClaimAllActiveConnections(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, strings.Repeat("a", 64)) }))
	defer s.Close()
	c := idleConfig(s.URL + "/fixed")
	c.Rate = 1
	r, err := run(c)
	if err == nil || r.Valid || r.Success != 1 || r.Idle.MeasuredActive != 1 || r.Idle.InitialActive != 2 {
		t.Fatalf("underfed pool claimed two active sockets: idle=%+v %v", r.Idle, err)
	}
}

func TestActiveOriginalSocketCannotBeReplaced(t *testing.T) {
	var mu sync.Mutex
	calls := map[string]int{}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls[r.RemoteAddr]++
		count := calls[r.RemoteAddr]
		mu.Unlock()
		if count == 2 {
			w.Header().Set("Connection", "close")
		}
		fmt.Fprint(w, strings.Repeat("a", 64))
	}))
	defer s.Close()
	c := idleConfig(s.URL + "/fixed")
	c.IdleConnections = 1
	r, err := run(c)
	mu.Lock()
	defer mu.Unlock()
	if err == nil || r.Valid || r.Errors == 0 || len(calls) != 3 || r.Idle.Replacements == 0 || r.Idle.EarlyActiveClosed != 2 {
		t.Fatalf("replacement/close hidden: sockets=%d idle=%+v result=%+v %v", len(calls), r.Idle, r, err)
	}
}

func TestBadInitialIdleResponseAndTimeoutCloseOwnedSockets(t *testing.T) {
	for _, fail := range []string{"body", "status", "chunked", "close", "timeout", "truncated", "extra", "dial"} {
		t.Run(fail, func(t *testing.T) {
			var closed atomic.Int64
			var s *httptest.Server
			s = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if fail == "timeout" {
					<-r.Context().Done()
					return
				}
				body := strings.Repeat("a", 64)
				if fail == "truncated" || fail == "extra" {
					conn, _, _ := w.(http.Hijacker).Hijack()
					defer conn.Close()
					if fail == "truncated" {
						body = strings.Repeat("a", 63)
					} else {
						body += "extra"
					}
					fmt.Fprint(conn, "HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\n"+body)
					return
				}
				if fail == "dial" {
					s.Listener.Close()
				}
				switch fail {
				case "body":
					body = strings.Repeat("z", 64)
				case "status":
					w.WriteHeader(503)
				case "chunked":
					w.(http.Flusher).Flush()
				case "close":
					w.Header().Set("Connection", "close")
				}
				fmt.Fprint(w, body)
			}))
			s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
				if state == http.StateClosed || state == http.StateHijacked {
					closed.Add(1)
				}
			}
			s.Start()
			defer s.Close()
			c := idleConfig(s.URL + "/fixed")
			c.SetupTimeout = 20 * time.Millisecond
			began := time.Now()
			r, err := run(c)
			wantInitial := 0
			if fail == "dial" {
				wantInitial = 1
			}
			if err == nil || r.Valid || r.Started != 0 || r.Idle.InitialIdle != wantInitial || time.Since(began) > time.Second {
				t.Fatalf("invalid setup accepted or unbounded: %+v %v", r, err)
			}
			deadline := time.Now().Add(time.Second)
			for closed.Load() != 1 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if closed.Load() != 1 {
				t.Fatalf("setup socket leaked: %d", closed.Load())
			}
		})
	}
}

func TestIdleConfigurationAndLoaderFDLimitGates(t *testing.T) {
	for _, change := range []func(*config){func(c *config) { c.IdleConnections = -1 }, func(c *config) { c.KeepAlive = false }, func(c *config) { c.SetupTimeout = 0 }, func(c *config) { c.URL = "http://localhost/json" }} {
		c := idleConfig("http://localhost/fixed")
		change(&c)
		if r, err := run(c); err == nil || r.Valid || r.Started != 0 {
			t.Fatalf("invalid idle configuration accepted: %+v %v", r, err)
		}
	}
}

func TestIdleFDLimitSubprocessGate(t *testing.T) {
	if os.Args[len(os.Args)-1] != "owned-fd-limit-child" {
		output, err := exec.Command(os.Args[0], "-test.run=^TestIdleFDLimitSubprocessGate$", "owned-fd-limit-child").CombinedOutput()
		if err != nil {
			t.Fatalf("owned child FD gate: %v %s", err, output)
		}
		return
	}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &syscall.Rlimit{Cur: 16, Max: 16}); err != nil {
		t.Fatal(err)
	}
	c := idleConfig("http://localhost/fixed")
	c.IdleConnections = 17
	if r, err := run(c); err == nil || r.Valid || r.Idle.LoaderFDSoft != 16 || r.Idle.LoaderFDHard != 16 || r.Idle.InitialIdle != 0 {
		t.Fatalf("FD limit failure hidden: %+v %v", r, err)
	}
}
