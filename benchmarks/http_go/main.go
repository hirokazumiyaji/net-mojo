// Go baseline for net-mojo HTTP benchmarks (Issue #42 Phase 0 / PR 9).
//
// Same handler shapes the Mojo server will implement, so throughput and
// p99 comparisons use identical request/response bytes and handler work:
//   - GET /fixed : 64 B fixed body.
//   - GET /json  : 1 KiB JSON built with the same field layout.
//   - POST /echo : bounded echo of the request body (Content-Length and
//     chunked both accepted by net/http), capped at 1 MiB.
//
// Plain HTTP/1.1: default listen. HTTPS + HTTP/2 (ALPN h2): pass -tls
// with -cert/-key (defaults to build/tls/test-cert.pem after tls-build).
//
// Logging is disabled and keep-alives are left on, matching the Mojo
// server defaults. Pin the server to one core with GOMAXPROCS=1 for the
// headline comparison, and run the load generator on separate CPUs or a
// separate host. See benchmarks/http/README.md for the full procedure.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/http2"
)

var fixedBody = []byte(strings.Repeat("a", 64))

var jsonBody = []byte(`{` +
	`"id":1234567890,` +
	`"name":"net-mojo baseline payload",` +
	`"tags":["http","benchmark","baseline","mojo","go","server","api","test"],` +
	`"nested":{"a":1,"b":2,"c":3,"d":4,"e":5},` +
	strings.Repeat(`"pad":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",`, 8) +
	`"ok":true}`)

func init() {
	// Pad or trim to exactly 1024 bytes so the byte count matches the
	// Mojo benchmark payload.
	if len(jsonBody) < 1024 {
		jsonBody = append(jsonBody, []byte(strings.Repeat(" ", 1024-len(jsonBody)))...)
	} else {
		jsonBody = jsonBody[:1024]
	}
}

func fixedHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", fmt.Sprint(len(fixedBody)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(fixedBody)
}

func jsonHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprint(len(jsonBody)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(jsonBody)
}

func echoHandler(w http.ResponseWriter, r *http.Request) {
	const maxBody = 1 << 20
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}
	// The body is now fully consumed: restart a 30s write phase so a
	// slow upload does not eat the response budget. Go arms
	// WriteTimeout at header completion, which would otherwise leave
	// about a second to write after a 29s body. Skipped for HTTP/2:
	// the deadline is connection-wide and would affect sibling streams.
	if r.ProtoMajor < 2 {
		if c, ok := r.Context().Value(connKey{}).(net.Conn); ok {
			_ = c.SetWriteDeadline(time.Now().Add(30 * time.Second))
		}
	}
	if len(body) > maxBody {
		http.Error(w, "Content Too Large", http.StatusRequestEntityTooLarge)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

type connKey struct{}

// withBodyDeadline resets the connection read deadline when the handler
// starts, i.e. right after net/http parsed the headers. Go's ReadTimeout
// otherwise runs from the first byte, so a client spending most
// of the header budget would steal time from the body phase that the
// Mojo server grants separately (5s headers, then a fresh 30s body).
// Skipped for multiplexed HTTP/2 (ProtoMajor == 2): the deadline would
// apply connection-wide and one stream could reset/expire siblings.
func withBodyDeadline(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor >= 2 {
			next.ServeHTTP(w, r)
			return
		}
		if c, ok := r.Context().Value(connKey{}).(net.Conn); ok {
			// Best effort: a failed reset just leaves ReadTimeout armed.
			_ = c.SetReadDeadline(time.Now().Add(30 * time.Second))
		}
		next.ServeHTTP(w, r)
	})
}

func listenBenchmark(address string) (net.Listener, error) {
	lc := net.ListenConfig{KeepAlive: -1}
	return lc.Listen(context.Background(), "tcp", address)
}

func main() {
	addr := flag.String("addr", "127.0.0.1:18080", "listen address")
	idleTimeout := flag.Duration("idle-timeout", 60*time.Second, "keepalive idle timeout (positive)")
	useTLS := flag.Bool("tls", false, "serve HTTPS (enables HTTP/2 via ALPN h2)")
	certFile := flag.String("cert", "build/tls/test-cert.pem", "TLS certificate (PEM)")
	keyFile := flag.String("key", "build/tls/test-key.pem", "TLS private key (PEM)")
	flag.Parse()
	if *idleTimeout <= 0 {
		log.Fatal("idle-timeout must be positive")
	}
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		log.Fatal(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"event": "fd_limits", "source": "getrlimit", "pid": os.Getpid(), "soft": limit.Cur, "hard": limit.Max,
	}); err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/fixed", fixedHandler)
	mux.HandleFunc("/json", jsonHandler)
	mux.HandleFunc("/echo", echoHandler)

	server := &http.Server{
		Addr:    *addr,
		Handler: withBodyDeadline(mux),
		// Go offers no split body deadline: ReadTimeout covers headers
		// plus body from the first byte, so it stays armed as a backstop
		// while withBodyDeadline restarts a 30s body phase after header
		// parse, matching the Mojo 5s-header/30s-body split.
		// ReadHeaderTimeout matches the Mojo header phase alone.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       35 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       *idleTimeout,
		ErrorLog:          log.New(io.Discard, "", 0),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, connKey{}, c)
		},
	}

	ln, err := listenBenchmark(*addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}

	proto := "http"
	if *useTLS {
		proto = "https+h2"
		server.TLSConfig = &tls.Config{
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"h2", "http/1.1"},
		}
		if err := http2.ConfigureServer(server, &http2.Server{}); err != nil {
			log.Fatalf("http2 configure: %v", err)
		}
	}

	fmt.Printf(
		"http_go baseline listening on %s proto=%s idle_timeout=%s (fixed=%dB json=%dB)\n",
		ln.Addr(),
		proto,
		server.IdleTimeout,
		len(fixedBody),
		len(jsonBody),
	)
	if *useTLS {
		if err := server.ServeTLS(ln, *certFile, *keyFile); err != nil && err != http.ErrServerClosed {
			log.Fatalf("serve tls: %v", err)
		}
		return
	}
	if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}
