package main

import (
	"bufio"
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type idleStats struct {
	RequestedTotal    int     `json:"requested_total"`
	InitialIdle       int     `json:"confirmed_idle_initial"`
	FinalIdle         int     `json:"confirmed_idle_final"`
	InitialActive     int     `json:"confirmed_active_initial"`
	MeasuredActive    int     `json:"active_used_in_measurement"`
	Replacements      uint64  `json:"forbidden_replacement_attempts"`
	EarlyActiveClosed int     `json:"active_closed_before_deadline"`
	LoaderFDSoft      uint64  `json:"loader_fd_limit_soft"`
	LoaderFDHard      uint64  `json:"loader_fd_limit_hard"`
	SetupSeconds      float64 `json:"setup_seconds"`
	PostflightSeconds float64 `json:"postflight_seconds"`
}

type heldSocket struct {
	net.Conn
	reader *bufio.Reader
}

func (s heldSocket) probe(ctx context.Context, c config, w workload) error {
	deadline := time.Now().Add(c.Timeout)
	if end, _ := ctx.Deadline(); end.Before(deadline) {
		deadline = end
	}
	if err := s.SetDeadline(deadline); err != nil {
		return err
	}
	req, err := http.NewRequest(w.method, c.URL, nil)
	if err != nil {
		return err
	}
	if err := req.Write(s.Conn); err != nil {
		return err
	}
	response, err := http.ReadResponse(s.reader, req)
	if err != nil {
		return err
	}
	if response.Close {
		response.Body.Close()
		return errors.New("idle response closes original connection")
	}
	if err := validateResponse(response, w); err != nil {
		return err
	}
	if s.reader.Buffered() != 0 {
		return errors.New("unsolicited bytes after idle response")
	}
	return s.SetDeadline(time.Time{})
}

type pinnedConn struct {
	net.Conn
	mu       sync.Mutex
	closedAt time.Time
}

func (c *pinnedConn) Close() error {
	c.mu.Lock()
	if c.closedAt.IsZero() {
		c.closedAt = time.Now()
	}
	c.mu.Unlock()
	return c.Conn.Close()
}

type pinnedTransport struct {
	*http.Transport
	conn                   *pinnedConn
	requests, replacements atomic.Uint64
	before                 uint64
}

func (t *pinnedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.requests.Add(1)
	response, err := t.Transport.RoundTrip(req)
	if err == nil && response.Close {
		response.Body.Close()
		return nil, errors.New("active response closes original connection")
	}
	return response, err
}

type idleSockets struct {
	idle    []heldSocket
	active  []*pinnedTransport
	clients []*http.Client
	stats   *idleStats
}

func (g *idleSockets) setup(c config, w workload) error {
	start := time.Now()
	defer func() { g.stats.SetupSeconds = time.Since(start).Seconds() }()
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		return err
	}
	g.stats.LoaderFDSoft, g.stats.LoaderFDHard = limit.Cur, limit.Max
	if uint64(g.stats.RequestedTotal) > limit.Cur {
		return errors.New("requested sockets exceed loader FD limit")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.SetupTimeout)
	defer cancel()
	u, _ := url.Parse(c.URL)
	port := u.Port()
	if port == "" {
		port = "80"
	}
	addr := net.JoinHostPort(u.Hostname(), port)
	dialer := benchmarkDialer(c.Timeout)
	for i := 0; i < c.IdleConnections; i++ {
		conn, err := dialer.DialContext(ctx, "tcp", addr)
		if err != nil {
			return err
		}
		socket := heldSocket{conn, bufio.NewReader(conn)}
		g.idle = append(g.idle, socket)
		if err := socket.probe(ctx, c, w); err != nil {
			return err
		}
		g.stats.InitialIdle++
	}
	for i := 0; i < c.Connections; i++ {
		conn, err := dialer.DialContext(ctx, "tcp", addr)
		if err != nil {
			return err
		}
		protocols := new(http.Protocols)
		protocols.SetHTTP1(true)
		t := &pinnedTransport{conn: &pinnedConn{Conn: conn}}
		var handed atomic.Bool
		t.Transport = &http.Transport{Protocols: protocols, DisableCompression: true,
			MaxConnsPerHost: 1, MaxIdleConns: 1, MaxIdleConnsPerHost: 1,
			DialContext: func(context.Context, string, string) (net.Conn, error) {
				if handed.Swap(true) {
					t.replacements.Add(1)
					return nil, errors.New("original active socket cannot be replaced")
				}
				return t.conn, nil
			}}
		g.active = append(g.active, t)
		client := &http.Client{Transport: t, Timeout: c.Timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		g.clients = append(g.clients, client)
		if err := request(ctx, client, c, w); err != nil {
			return err
		}
		g.stats.InitialActive++
	}
	return nil
}

func (g *idleSockets) beginMeasurement() {
	for _, t := range g.active {
		t.before = t.requests.Load()
	}
}

func (g *idleSockets) finishActive(deadline time.Time) {
	for _, t := range g.active {
		if t.requests.Load() > t.before {
			g.stats.MeasuredActive++
		}
		g.stats.Replacements += t.replacements.Load()
		t.conn.mu.Lock()
		if !t.conn.closedAt.IsZero() && t.conn.closedAt.Before(deadline) {
			g.stats.EarlyActiveClosed++
		}
		t.conn.mu.Unlock()
	}
}

func (g *idleSockets) postflight(c config, w workload) error {
	start := time.Now()
	defer func() { g.stats.PostflightSeconds = time.Since(start).Seconds() }()
	ctx, cancel := context.WithTimeout(context.Background(), c.SetupTimeout)
	defer cancel()
	for _, socket := range g.idle {
		if err := socket.probe(ctx, c, w); err != nil {
			return err
		}
		g.stats.FinalIdle++
	}
	return nil
}

func (g *idleSockets) close() {
	for _, socket := range g.idle {
		socket.Close()
	}
	for _, t := range g.active {
		t.CloseIdleConnections()
		t.conn.Close()
	}
}
