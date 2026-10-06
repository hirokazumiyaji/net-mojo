//go:build darwin || linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"syscall"
	"testing"
	"time"
)

func assertBenchmarkTCPOptions(t *testing.T, label string, conn net.Conn) {
	t.Helper()
	raw, err := conn.(*net.TCPConn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	for _, option := range []struct {
		name          string
		level, option int
		want          bool
	}{
		{"SO_KEEPALIVE", syscall.SOL_SOCKET, syscall.SO_KEEPALIVE, false},
		{"TCP_NODELAY", syscall.IPPROTO_TCP, syscall.TCP_NODELAY, true},
	} {
		var value int
		var queryErr error
		err = raw.Control(func(fd uintptr) {
			value, queryErr = syscall.GetsockoptInt(int(fd), option.level, option.option)
		})
		if err != nil || queryErr != nil {
			t.Fatalf("%s %s query: %v %v", label, option.name, err, queryErr)
		}
		enabled := value != 0
		t.Logf("%s %s raw=%d enabled=%v", label, option.name, value, enabled)
		if enabled != option.want {
			t.Errorf("%s %s raw=%d enabled=%v, want enabled=%v", label, option.name, value, enabled, option.want)
		}
	}
}

func TestBenchmarkAcceptedTCPKeepaliveOffPreservesHTTPReuse(t *testing.T) {
	listener, err := listenBenchmark("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	accepted := make(chan net.Conn, 1)
	server := &http.Server{
		Handler: withBodyDeadline(http.HandlerFunc(fixedHandler)),
		ConnContext: func(ctx context.Context, conn net.Conn) context.Context {
			accepted <- conn
			return context.WithValue(ctx, connKey{}, conn)
		},
	}
	finished := make(chan error, 1)
	go func() { finished <- server.Serve(listener) }()
	defer func() {
		if err := server.Close(); err != nil {
			t.Error(err)
		}
		select {
		case err := <-finished:
			if err != http.ErrServerClosed {
				t.Errorf("server exit: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Error("owned server did not terminate")
		}
	}()
	dialer := net.Dialer{Timeout: time.Second, KeepAlive: -1}
	conn, err := dialer.DialContext(context.Background(), "tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	select {
	case peer := <-accepted:
		assertBenchmarkTCPOptions(t, "accepted server", peer)
	case <-time.After(time.Second):
		t.Fatal("server did not accept owned client")
	}
	reader := bufio.NewReader(conn)
	for ordinal := 0; ordinal < 2; ordinal++ {
		req, err := http.NewRequest("GET", "http://"+listener.Addr().String()+"/fixed", nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := req.Write(conn); err != nil {
			t.Fatal(err)
		}
		response, err := http.ReadResponse(reader, req)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != 200 || response.Close || !bytes.Equal(body, fixedBody) {
			t.Fatalf("original socket request %d: status=%d close=%v body=%q error=%v", ordinal, response.StatusCode, response.Close, body, err)
		}
	}
}
