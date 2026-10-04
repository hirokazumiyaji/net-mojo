package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testConfig(url string) config {
	return config{URL: url, Connections: 1, Duration: 30 * time.Millisecond,
		BodySize: 64, KeepAlive: true, Timeout: time.Second}
}

func TestRejectInvalidConfigurations(t *testing.T) {
	for _, change := range []func(*config){
		func(c *config) { c.URL = "https://localhost/fixed" },
		func(c *config) { c.URL = "http:///fixed" },
		func(c *config) { c.URL = "http://localhost/unknown" },
		func(c *config) { c.Connections = 0 },
		func(c *config) { c.Duration = 0 },
		func(c *config) { c.Warmup = -1 },
		func(c *config) { c.Timeout = 0 },
		func(c *config) { c.BodySize = -1 },
		func(c *config) { c.BodySize = 1<<20 + 1 },
		func(c *config) { c.Method = "POST" },
		func(c *config) { c.Chunked = true },
	} {
		c := testConfig("http://localhost/fixed")
		change(&c)
		if _, err := run(c); err == nil {
			t.Errorf("accepted invalid configuration: %+v", c)
		}
	}
}

func TestValidateRealResponses(t *testing.T) {
	for _, name := range []string{"valid", "bad-body", "bad-status", "bad-length", "truncated", "chunked-response", "redirect", "bad-proto"} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body := strings.Repeat("a", 64)
				switch name {
				case "bad-body":
					body = strings.Repeat("z", 64)
				case "bad-status":
					w.WriteHeader(503)
				case "bad-length":
					w.Header().Set("Content-Length", "65")
				case "truncated":
					w.Header().Set("Content-Length", "64")
					body = strings.Repeat("a", 63)
				case "chunked-response":
					w.(http.Flusher).Flush()
				case "redirect":
					w.Header().Set("Location", "/fixed")
					w.WriteHeader(302)
				case "bad-proto":
					conn, _, _ := w.(http.Hijacker).Hijack()
					defer conn.Close()
					fmt.Fprint(conn, "HTTP/1.0 200 OK\r\nContent-Length: 64\r\n\r\n"+body)
					return
				}
				io.WriteString(w, body)
			}))
			defer server.Close()
			result, err := run(testConfig(server.URL + "/fixed"))
			if name == "valid" {
				if err != nil || !result.Valid || result.Success == 0 || result.Samples != result.Success || result.ResponseBytes != result.Success*64 {
					t.Fatalf("valid response rejected: %+v %v", result, err)
				}
			} else if err == nil || result.Valid || result.Errors == 0 || result.Success != 0 {
				t.Fatalf("invalid response counted as success: %+v %v", result, err)
			}
			if result.Started != result.Success+result.Errors+result.Cutoff {
				t.Fatalf("unaccounted requests: %+v", result)
			}
		})
	}
}

func TestEchoRequestFramingAndConnectionReuse(t *testing.T) {
	for _, chunked := range []bool{false, true} {
		for _, keepAlive := range []bool{false, true} {
			var mu sync.Mutex
			addresses := map[string]bool{}
			bad := false
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				mu.Lock()
				addresses[r.RemoteAddr] = true
				bad = bad || r.Proto != "HTTP/1.1" || r.Method != "POST" || r.Header.Get("Accept-Encoding") != "" || !bytes.Equal(body, bytes.Repeat([]byte("b"), 1024))
				bad = bad || (chunked && (r.ContentLength != -1 || len(r.TransferEncoding) != 1 || r.TransferEncoding[0] != "chunked")) || (!chunked && r.ContentLength != 1024)
				mu.Unlock()
				w.Header().Set("Content-Length", "1024")
				w.Write(body)
			}))
			c := testConfig(server.URL + "/echo")
			c.BodySize, c.Chunked, c.KeepAlive = 1024, chunked, keepAlive
			c.Warmup = 20 * time.Millisecond
			result, err := run(c)
			server.Close()
			mu.Lock()
			if err != nil || bad || result.Success < 2 || result.RequestBodyBytes != result.Success*1024 || result.WarmupCounts.Success == 0 {
				t.Fatalf("echo/framing failure: %+v bad=%v err=%v", result, bad, err)
			}
			if (keepAlive && len(addresses) != 1) || (!keepAlive && len(addresses) < 2) {
				t.Fatalf("keepalive=%v used %d connections", keepAlive, len(addresses))
			}
			mu.Unlock()
		}
	}
}

func TestDeadlineCutoffFailsZeroWorkWithoutInflatingWindow(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	c := testConfig(server.URL + "/fixed")
	c.Duration = 10 * time.Millisecond
	result, err := run(c)
	if err == nil || result.Valid || result.Success != 0 || result.Cutoff != 1 || result.Errors != 0 || result.ElapsedSeconds != .01 || result.Samples != 0 {
		t.Fatalf("deadline/zero-work gate: %+v %v", result, err)
	}
}

func TestRequestTimeoutBeforeWindowEndIsError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	c := testConfig(server.URL + "/fixed")
	c.Timeout = 2 * time.Millisecond
	result, err := run(c)
	if err == nil || result.Errors == 0 || result.Success != 0 {
		t.Fatalf("timeout counted as success/cutoff: %+v %v", result, err)
	}
}

func TestJSONFixtureAndWarmupFailure(t *testing.T) {
	json := `{"id":1234567890,"name":"net-mojo baseline payload","tags":["http","benchmark","baseline","mojo","go","server","api","test"],"nested":{"a":1,"b":2,"c":3,"d":4,"e":5},` + strings.Repeat(`"pad":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",`, 8) + `"ok":true}`
	json += strings.Repeat(" ", 1024-len(json))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, json) }))
	defer server.Close()
	c := testConfig(server.URL + "/json")
	result, err := run(c)
	if err != nil || result.ResponseBytes != result.Success*1024 {
		t.Fatalf("JSON bytes: %+v %v", result, err)
	}
	c.URL, c.Warmup = server.URL+"/fixed", 10*time.Millisecond
	result, err = run(c)
	if err == nil || result.Started != 0 || result.WarmupCounts.Errors == 0 {
		t.Fatalf("broken warmup measured: %+v %v", result, err)
	}
}

func TestWarmupValidatesResponseDrainedAfterDeadline(t *testing.T) {
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := strings.Repeat("a", 64)
		if calls.Add(1) == 2 {
			time.Sleep(30 * time.Millisecond)
			body = strings.Repeat("z", 64)
		}
		fmt.Fprint(w, body)
	}))
	defer server.Close()
	c := testConfig(server.URL + "/fixed")
	c.Warmup = 15 * time.Millisecond
	r, err := run(c)
	if err == nil || r.Started != 0 || r.WarmupCounts.Errors != 1 || r.WarmupCounts.Cutoff != 0 {
		t.Fatalf("late warmup validation failure hidden: %+v %v", r, err)
	}
}

func TestNearestRankLatencyStatistics(t *testing.T) {
	samples := []time.Duration{5 * time.Millisecond, time.Millisecond, 3 * time.Millisecond, 2 * time.Millisecond, 4 * time.Millisecond}
	got := latencies(samples)
	if got.P50 != 3 || got.P95 != 5 || got.P99 != 5 {
		t.Fatalf("percentiles: %+v", got)
	}
	if got := latencies(nil); got.P50 != 0 || got.P95 != 0 || got.P99 != 0 {
		t.Fatalf("empty percentiles: %+v", got)
	}
}
