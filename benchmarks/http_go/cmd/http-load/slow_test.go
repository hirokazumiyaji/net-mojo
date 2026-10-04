package main

import (
	"bytes"
	"fmt"
	"io"
	"math"
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

func slowTotal(s *slowStats) slowCohort {
	return slowCohort{Initial: s.Headers.Initial + s.Bodies.Initial, Final: s.Headers.Final + s.Bodies.Final, Closed: s.Headers.Closed + s.Bodies.Closed, MeasuredUsed: s.Headers.MeasuredUsed + s.Bodies.MeasuredUsed}
}

func slowConfig(url string) config {
	c := testConfig(url)
	c.Connections, c.SlowHeaders, c.SlowBodies = 2, 1, 1
	c.Duration, c.Warmup = 120*time.Millisecond, 20*time.Millisecond
	c.SlowInterval, c.SetupTimeout = time.Millisecond, time.Second
	return c
}

func TestSlowOriginalSocketsExchangeHeadersAndExactBodiesAlongsideOrdinaryWork(t *testing.T) {
	for _, rate := range []int{0, 200} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			var mu sync.Mutex
			roles := map[string]string{}
			calls := map[string]int{}
			var opened, closed, uploads, overlap atomic.Int64
			var bad atomic.Bool
			s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				role := "ordinary"
				if _, ok := r.Header["X-Slow"]; ok {
					role = "header"
				}
				if r.URL.Path == "/echo" {
					role = "body"
					uploads.Add(1)
					body, err := io.ReadAll(r.Body)
					uploads.Add(-1)
					if err != nil || r.Header.Get("Expect") != "100-continue" || r.ContentLength != 65536 || !bytes.Equal(body, bytes.Repeat([]byte("b"), 65536)) {
						bad.Store(true)
					}
					w.Header().Set("Content-Length", fmt.Sprint(len(body)))
					w.Write(body)
				} else {
					if uploads.Load() > 0 {
						overlap.Add(1)
					}
					io.WriteString(w, strings.Repeat("a", 64))
				}
				mu.Lock()
				calls[r.RemoteAddr]++
				if role != "ordinary" {
					roles[r.RemoteAddr] = role
				}
				mu.Unlock()
			}))
			s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
				if state == http.StateNew {
					opened.Add(1)
				}
				if state == http.StateClosed {
					closed.Add(1)
				}
			}
			s.Start()
			defer s.Close()
			c := slowConfig(s.URL + "/fixed")
			c.Rate = rate
			r, err := run(c)
			if err != nil || !r.Valid || r.Slow == nil || slowTotal(r.Slow).Initial != 2 || slowTotal(r.Slow).Final != 2 || slowTotal(r.Slow).Closed != 2 || bad.Load() || overlap.Load() == 0 {
				t.Fatalf("mixed validated original sockets absent: result=%+v slow=%+v bad=%v overlap=%d err=%v", r, r.Slow, bad.Load(), overlap.Load(), err)
			}
			for _, pair := range []struct {
				ordinary *phaseWindow
				slow     *slowWindow
			}{{r.WarmupWindow, r.Slow.Warmup}, {r.MeasurementWindow, r.Slow.Measured}} {
				if pair.slow == nil || *pair.slow.Window != *pair.ordinary || pair.slow.Headers.IncompleteNS <= 0 || pair.slow.Bodies.IncompleteNS <= 0 || pair.slow.Headers.DripBytes == 0 || pair.slow.Bodies.DripBytes == 0 {
					t.Fatalf("traffic/window evidence absent: %+v", pair.slow)
				}
			}
			if r.Started != r.Success+r.Errors+r.Cutoff || r.Samples != r.Success || r.ResponseBytes != r.Success*64 || r.Slow.TotalCycles < 2 || r.Slow.FDSoft == 0 || slowTotal(r.Slow).MeasuredUsed != 2 {
				t.Fatalf("ordinary/profile accounting changed: %+v slow=%+v", r, r.Slow)
			}
			mu.Lock()
			roleCount := len(roles)
			var incomplete string
			for address := range roles {
				if calls[address] < 3 {
					incomplete = address
				}
			}
			mu.Unlock()
			if roleCount != 2 {
				t.Fatalf("slow profiles used %d original sockets: %+v", len(roles), roles)
			}
			if incomplete != "" {
				t.Fatalf("socket %s lacks preflight/profile/postflight", incomplete)
			}
			deadline := time.Now().Add(time.Second)
			for closed.Load() != opened.Load() && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if closed.Load() != opened.Load() {
				t.Fatalf("owned sockets leaked: opened=%d closed=%d", opened.Load(), closed.Load())
			}
		})
	}
}

func TestSlowConfigurationScopeAndTiming(t *testing.T) {
	for _, change := range []func(*config){
		func(c *config) { c.SlowHeaders = -1 },
		func(c *config) { c.SlowBodies = -1 },
		func(c *config) { c.SlowHeaders = math.MaxInt },
		func(c *config) { c.SlowBodies = math.MaxInt },
		func(c *config) { c.KeepAlive = false },
		func(c *config) { c.IdleConnections = 1 },
		func(c *config) { c.URL = "http://localhost/json" },
		func(c *config) { c.SetupTimeout = 0 },
		func(c *config) { c.SlowInterval = 0 },
		func(c *config) { c.SlowInterval = 30 * time.Second / 64 },
	} {
		c := slowConfig("http://localhost/fixed")
		change(&c)
		if _, err := prepare(c); err == nil {
			t.Fatalf("invalid slow configuration accepted: %+v", c)
		}
	}
}

func TestSlowBadContinueEchoAndPostflightInvalidateAndJoin(t *testing.T) {
	for _, fail := range []string{"continue", "continue-length", "echo", "postflight"} {
		t.Run(fail, func(t *testing.T) {
			var mu sync.Mutex
			first := ""
			probes := 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/echo" {
					if strings.HasPrefix(fail, "continue") {
						conn, _, err := w.(http.Hijacker).Hijack()
						if err != nil {
							panic(err)
						}
						defer conn.Close()
						status, length := "200 OK", "Content-Length: 0\r\n"
						if fail == "continue-length" {
							status, length = "100 Continue", "Content-Length: 1\r\n"
						}
						fmt.Fprintf(conn, "HTTP/1.1 %s\r\n%s\r\n", status, length)
						return
					}
					body, _ := io.ReadAll(r.Body)
					if fail == "echo" {
						body[0] = 'z'
					}
					w.Header().Set("Content-Length", fmt.Sprint(len(body)))
					w.Write(body)
					return
				}
				mu.Lock()
				if first == "" {
					first = r.RemoteAddr
				}
				if first == r.RemoteAddr && r.Header.Get("X-Slow") == "" {
					probes++
				}
				wrong := fail == "postflight" && first == r.RemoteAddr && probes == 2
				mu.Unlock()
				body := strings.Repeat("a", 64)
				if wrong {
					body = strings.Repeat("z", 64)
				}
				io.WriteString(w, body)
			}))
			defer s.Close()
			c := slowConfig(s.URL + "/fixed")
			c.Warmup = 0
			began := time.Now()
			r, err := run(c)
			if err == nil || r.Valid || slowTotal(r.Slow).Closed != 2 || slowTotal(r.Slow).Final == 2 || time.Since(began) > time.Second {
				t.Fatalf("bad profile accepted/leaked/unbounded: %+v slow=%+v err=%v", r, r.Slow, err)
			}
		})
	}
}

func TestSlowPartialSetupClosesOnlyOwnedOriginalSockets(t *testing.T) {
	var accepted, closed atomic.Int64
	var s *httptest.Server
	s = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		s.Listener.Close()
		io.WriteString(w, strings.Repeat("a", 64))
	}))
	s.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			accepted.Add(1)
		}
		if state == http.StateClosed {
			closed.Add(1)
		}
	}
	s.Start()
	defer s.Close()
	r, err := run(slowConfig(s.URL + "/fixed"))
	if err == nil || r.Started != 0 || slowTotal(r.Slow).Initial != 1 || slowTotal(r.Slow).Closed != 1 || r.MeasurementWindow != nil {
		t.Fatalf("partial setup hidden: %+v slow=%+v err=%v", r, r.Slow, err)
	}
	deadline := time.Now().Add(time.Second)
	for closed.Load() != accepted.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if closed.Load() != accepted.Load() {
		t.Fatal("partial setup leaked")
	}
}

func TestSlowUnusedMeasurementAndOrdinaryOverloadStayInvalid(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/echo" {
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.Write(body)
			return
		}
		time.Sleep(15 * time.Millisecond)
		io.WriteString(w, strings.Repeat("a", 64))
	}))
	defer s.Close()
	c := slowConfig(s.URL + "/fixed")
	c.Warmup, c.Duration, c.SlowInterval = 0, 40*time.Millisecond, 100*time.Millisecond
	r, err := run(c)
	if err == nil || r.Valid || r.Success == 0 || slowTotal(r.Slow).MeasuredUsed != 0 || slowTotal(r.Slow).Final != 2 {
		t.Fatalf("unfed slow sockets claimed measured traffic: %+v slow=%+v err=%v", r, r.Slow, err)
	}
	c.Connections, c.Rate, c.Duration, c.SlowInterval = 1, 1000, 90*time.Millisecond, time.Millisecond
	r, err = run(c)
	if err == nil || r.Valid || r.Arrivals.Dropped == 0 || slowTotal(r.Slow).Final != 2 || r.Started != r.Success+r.Errors+r.Cutoff || r.Arrivals.Scheduled != r.Started+r.Arrivals.Dropped+r.Arrivals.Unstarted {
		t.Fatalf("ordinary overload hidden with profiles: %+v slow=%+v err=%v", r, r.Slow, err)
	}
}

func TestSlowFDLimitSubprocessGate(t *testing.T) {
	if os.Args[len(os.Args)-1] != "owned-slow-fd-child" {
		output, err := exec.Command(os.Args[0], "-test.run=^TestSlowFDLimitSubprocessGate$", "owned-slow-fd-child").CombinedOutput()
		if err != nil {
			t.Fatalf("owned child FD gate: %v %s", err, output)
		}
		return
	}
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &syscall.Rlimit{Cur: 16, Max: 16}); err != nil {
		t.Fatal(err)
	}
	c := slowConfig("http://localhost/fixed")
	c.SlowHeaders = 17
	r, err := run(c)
	if err == nil || r.Valid || r.Slow.FDSoft != 16 || r.Slow.FDHard != 16 || slowTotal(r.Slow).Initial != 0 || slowTotal(r.Slow).Closed != 0 {
		t.Fatalf("FD gate failure hidden: %+v slow=%+v err=%v", r, r.Slow, err)
	}
}

func TestSlowWithheldContinueResponseAndPostflightWaitsAreBounded(t *testing.T) {
	for _, stall := range []string{"continue", "echo", "postflight"} {
		t.Run(stall, func(t *testing.T) {
			var mu sync.Mutex
			first, probes := "", 0
			entered, joined := make(chan struct{}, 1), make(chan struct{}, 1)
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				if first == "" {
					first = r.RemoteAddr
				}
				if r.RemoteAddr == first && r.Header.Get("X-Slow") == "" {
					probes++
				}
				postflight := r.RemoteAddr == first && probes == 2
				mu.Unlock()
				if r.URL.Path == "/echo" && stall != "continue" {
					io.Copy(io.Discard, r.Body)
				}
				if (r.URL.Path == "/echo" && stall != "postflight") || (stall == "postflight" && postflight) {
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						panic(err)
					}
					entered <- struct{}{}
					defer func() { joined <- struct{}{} }()
					defer conn.Close()
					conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
					io.Copy(io.Discard, conn)
					return
				}
				if r.URL.Path == "/echo" {
					w.Header().Set("Content-Length", "65536")
					w.Write(bytes.Repeat([]byte("b"), 65536))
					return
				}
				io.WriteString(w, strings.Repeat("a", 64))
			}))
			defer s.Close()
			c := slowConfig(s.URL + "/fixed")
			c.Warmup, c.Duration, c.Timeout, c.SetupTimeout = 0, 30*time.Millisecond, 40*time.Millisecond, 20*time.Millisecond
			began := time.Now()
			r, err := run(c)
			select {
			case <-entered:
			default:
				t.Fatal("fixture did not enter the withheld/stalled peer path")
			}
			select {
			case <-joined:
			case <-time.After(time.Second):
				t.Fatal("owned stalled peer did not join")
			}
			if err == nil || r.Valid || slowTotal(r.Slow).Closed != 2 || slowTotal(r.Slow).Final == 2 || time.Since(began) > time.Second {
				t.Fatalf("stalled peer wait escaped deadline/join: result=%+v slow=%+v err=%v", r, r.Slow, err)
			}
			if stall == "continue" && r.Started != 0 {
				t.Fatal("unconfirmed100 body entered workload")
			}
		})
	}
}
