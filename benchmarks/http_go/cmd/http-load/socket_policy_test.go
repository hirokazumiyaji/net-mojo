//go:build darwin || linux

package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestBenchmarkLoaderTCPKeepaliveOffForEverySocketMode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/echo" {
			body, err := io.ReadAll(req.Body)
			if err != nil {
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.Write(body)
			return
		}
		io.WriteString(w, strings.Repeat("a", 64))
	}))
	defer server.Close()
	t.Run("ordinary", func(t *testing.T) {
		dialer := benchmarkDialer(time.Second)
		conn, err := dialer.DialContext(context.Background(), "tcp", server.Listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		assertBenchmarkTCPOptions(t, "ordinary client", conn)
	})
	t.Run("original idle and active", func(t *testing.T) {
		c := idleConfig(server.URL + "/fixed")
		w, err := prepare(c)
		if err != nil {
			t.Fatal(err)
		}
		group := &idleSockets{stats: &idleStats{RequestedTotal: c.IdleConnections + c.Connections}}
		defer group.close()
		if err := group.setup(c, w); err != nil {
			t.Fatal(err)
		}
		if len(group.idle) != c.IdleConnections || len(group.active) != c.Connections {
			t.Fatalf("incomplete original cohort: %+v", group.stats)
		}
		for ordinal, socket := range group.idle {
			assertBenchmarkTCPOptions(t, fmt.Sprintf("original idle %d", ordinal), socket.Conn)
		}
		for ordinal, transport := range group.active {
			assertBenchmarkTCPOptions(t, fmt.Sprintf("original active %d", ordinal), transport.conn.Conn)
		}
	})
	t.Run("slow headers bodies and readers", func(t *testing.T) {
		c := slowConfig(server.URL + "/fixed")
		c.SlowReaders = 1
		w, err := prepare(c)
		if err != nil {
			t.Fatal(err)
		}
		group := &slowSockets{stats: &slowStats{HeaderTicks: 8, BodyBytes: 65536, BodyChunkBytes: 1024,
			Headers: slowCohort{Requested: c.SlowHeaders}, Bodies: slowCohort{Requested: c.SlowBodies}, Readers: slowCohort{Requested: c.SlowReaders},
			ReaderBatchRequests: 8, ReaderBodyBytes: 1 << 20, ReaderChunkBytes: 1 << 16,
			ReaderIOBudgetNS: int64(30 * time.Second), ReaderBatchCapNS: int64(c.SetupTimeout), ReaderPressure: "unverified"}}
		defer group.close()
		if err := group.setup(c, w); err != nil {
			t.Fatal(err)
		}
		if len(group.sockets) != c.SlowHeaders+c.SlowBodies+c.SlowReaders {
			t.Fatalf("incomplete slow cohort: %d", len(group.sockets))
		}
		for ordinal, socket := range group.sockets {
			assertBenchmarkTCPOptions(t, fmt.Sprintf("slow client %d body=%v reader=%v", ordinal, socket.body, socket.isReader), socket.Conn)
		}
	})
}
