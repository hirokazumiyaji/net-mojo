package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type config struct {
	URL         string        `json:"url"`
	Connections int           `json:"connections"`
	Warmup      time.Duration `json:"warmup_ns"`
	Duration    time.Duration `json:"duration_ns"`
	Method      string        `json:"method"`
	BodySize    int           `json:"body_size"`
	Chunked     bool          `json:"chunked"`
	KeepAlive   bool          `json:"keepalive"`
	Timeout     time.Duration `json:"request_timeout_ns"`
}

type counts struct {
	Started uint64 `json:"started"`
	Success uint64 `json:"success"`
	Errors  uint64 `json:"errors"`
	Cutoff  uint64 `json:"cutoff"`
}

type latencyStats struct {
	P50 float64 `json:"p50"`
	P95 float64 `json:"p95"`
	P99 float64 `json:"p99"`
}

type result struct {
	Config config `json:"config"`
	counts
	WarmupCounts           counts       `json:"warmup_counts"`
	ElapsedSeconds         float64      `json:"elapsed_seconds"`
	Samples                uint64       `json:"samples"`
	RequestBodyBytes       uint64       `json:"request_body_bytes"`
	ResponseBytes          uint64       `json:"response_bytes"`
	RequestsPerSecond      float64      `json:"requests_per_second"`
	ResponseBytesPerSecond float64      `json:"response_bytes_per_second"`
	LatencyMS              latencyStats `json:"latency_ms"`
	Valid                  bool         `json:"valid"`
	FirstError             string       `json:"first_error,omitempty"`
}

type workload struct {
	method   string
	body     []byte
	expected []byte
}

func prepare(c config) (workload, error) {
	u, err := url.Parse(c.URL)
	if err != nil || u.Scheme != "http" || u.Host == "" || u.User != nil || u.Fragment != "" {
		return workload{}, errors.New("url must be a plain HTTP URL without credentials or fragment")
	}
	if c.Connections <= 0 || c.Duration <= 0 || c.Warmup < 0 || c.Timeout <= 0 || c.BodySize < 0 || c.BodySize > 1<<20 {
		return workload{}, errors.New("connections/duration/timeout must be positive; warmup >= 0; body-size 0..1048576")
	}
	w := workload{method: "GET"}
	switch u.Path {
	case "/fixed":
		w.expected = bytes.Repeat([]byte("a"), 64)
	case "/json":
		body := `{"id":1234567890,"name":"net-mojo baseline payload","tags":["http","benchmark","baseline","mojo","go","server","api","test"],"nested":{"a":1,"b":2,"c":3,"d":4,"e":5},` + strings.Repeat(`"pad":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",`, 8) + `"ok":true}`
		w.expected = []byte(body + strings.Repeat(" ", 1024-len(body)))
	case "/echo":
		w.method = "POST"
		w.body = bytes.Repeat([]byte("b"), c.BodySize)
		w.expected = w.body
	default:
		return workload{}, errors.New("url path must be /fixed, /json or /echo")
	}
	if (c.Method != "" && c.Method != w.method) || (c.Chunked && w.method != "POST") {
		return workload{}, errors.New("fixed/json require GET; echo requires POST; chunked requires echo")
	}
	return w, nil
}

func request(ctx context.Context, client *http.Client, c config, w workload) error {
	var body io.Reader
	if w.method == "POST" {
		body = io.NopCloser(bytes.NewReader(w.body))
	}
	req, err := http.NewRequestWithContext(ctx, w.method, c.URL, body)
	if err != nil {
		return err
	}
	if w.method == "POST" {
		req.ContentLength = int64(len(w.body))
		if c.Chunked {
			req.ContentLength = -1
			req.TransferEncoding = []string{"chunked"}
		}
	}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || response.Proto != "HTTP/1.1" || response.ContentLength != int64(len(w.expected)) || response.Header.Get("Content-Length") == "" {
		return fmt.Errorf("unexpected response: status=%d proto=%s content-length=%d", response.StatusCode, response.Proto, response.ContentLength)
	}
	received, err := io.ReadAll(io.LimitReader(response.Body, int64(len(w.expected))+1))
	if err != nil {
		return err
	}
	if !bytes.Equal(received, w.expected) {
		return errors.New("response body differs from benchmark payload")
	}
	return nil
}

type phaseResult struct {
	counts
	samples []time.Duration
	error   string
}

func phase(client *http.Client, c config, w workload, duration time.Duration, sample bool) phaseResult {
	start := make(chan struct{})
	results := make(chan phaseResult, c.Connections)
	var ready sync.WaitGroup
	ready.Add(c.Connections)
	var deadline time.Time
	var ctx context.Context
	for i := 0; i < c.Connections; i++ {
		go func() {
			ready.Done()
			<-start
			var r phaseResult
			for {
				began := time.Now()
				if !began.Before(deadline) {
					break
				}
				r.Started++
				err := request(ctx, client, c, w)
				finished := time.Now()
				if sample && !finished.Before(deadline) {
					r.Cutoff++
				} else if err != nil {
					r.Errors++
					if r.error == "" {
						r.error = err.Error()
					}
				} else {
					r.Success++
					if sample {
						r.samples = append(r.samples, finished.Sub(began))
					}
				}
			}
			results <- r
		}()
	}
	ready.Wait()
	deadline = time.Now().Add(duration)
	var cancel context.CancelFunc
	if sample {
		ctx, cancel = context.WithDeadline(context.Background(), deadline)
	} else {
		ctx, cancel = context.WithCancel(context.Background())
	}
	defer cancel()
	close(start)
	var total phaseResult
	for i := 0; i < c.Connections; i++ {
		r := <-results
		total.Started += r.Started
		total.Success += r.Success
		total.Errors += r.Errors
		total.Cutoff += r.Cutoff
		total.samples = append(total.samples, r.samples...)
		if total.error == "" {
			total.error = r.error
		}
	}
	return total
}

func latencies(samples []time.Duration) latencyStats {
	if len(samples) == 0 {
		return latencyStats{}
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	percentile := func(p float64) float64 {
		return float64(samples[int(math.Ceil(p*float64(len(samples))))-1]) / float64(time.Millisecond)
	}
	return latencyStats{percentile(.50), percentile(.95), percentile(.99)}
}

func run(c config) (result, error) {
	r := result{Config: c}
	w, err := prepare(c)
	if err != nil {
		return r, err
	}
	c.Method = w.method
	r.Config = c
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	transport := &http.Transport{
		Protocols: protocols, DisableCompression: true, DisableKeepAlives: !c.KeepAlive,
		MaxConnsPerHost: c.Connections, MaxIdleConns: c.Connections, MaxIdleConnsPerHost: c.Connections,
		DialContext: (&net.Dialer{Timeout: c.Timeout}).DialContext,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: c.Timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	if c.Warmup > 0 {
		warm := phase(client, c, w, c.Warmup, false)
		r.WarmupCounts, r.FirstError = warm.counts, warm.error
		if warm.Errors > 0 || warm.Success == 0 {
			return r, errors.New("warmup failed validation or completed no valid requests")
		}
	}
	measured := phase(client, c, w, c.Duration, true)
	r.counts, r.FirstError = measured.counts, measured.error
	r.ElapsedSeconds = c.Duration.Seconds()
	r.Samples = uint64(len(measured.samples))
	r.RequestBodyBytes = r.Success * uint64(len(w.body))
	r.ResponseBytes = r.Success * uint64(len(w.expected))
	r.RequestsPerSecond = float64(r.Success) / r.ElapsedSeconds
	r.ResponseBytesPerSecond = float64(r.ResponseBytes) / r.ElapsedSeconds
	r.LatencyMS = latencies(measured.samples)
	r.Valid = r.Success > 0 && r.Errors == 0
	if !r.Valid {
		return r, errors.New("measurement failed validation or completed no valid requests")
	}
	return r, nil
}

func main() {
	var c config
	flag.StringVar(&c.URL, "url", "http://127.0.0.1:18081/fixed", "benchmark URL (/fixed, /json, /echo)")
	flag.IntVar(&c.Connections, "connections", 64, "sequential request workers")
	flag.DurationVar(&c.Warmup, "warmup", 10*time.Second, "warmup before measurement (0 disables)")
	flag.DurationVar(&c.Duration, "duration", 30*time.Second, "fixed measurement window")
	flag.StringVar(&c.Method, "method", "", "request method (default GET, or POST for echo)")
	flag.IntVar(&c.BodySize, "body-size", 64, "echo request body bytes (0..1048576)")
	flag.BoolVar(&c.Chunked, "chunked", false, "send echo request with chunked framing")
	flag.BoolVar(&c.KeepAlive, "keepalive", true, "reuse connections")
	flag.DurationVar(&c.Timeout, "timeout", 5*time.Second, "maximum individual request duration")
	flag.Parse()
	r, err := run(c)
	if outputErr := json.NewEncoder(os.Stdout).Encode(r); outputErr != nil {
		fmt.Fprintln(os.Stderr, outputErr)
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
