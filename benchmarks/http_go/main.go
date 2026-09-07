// Go baseline for net-mojo HTTP benchmarks (Issue #42 Phase 0).
//
// Same handler shapes the Mojo server will implement, so throughput and
// p99 comparisons use identical request/response bytes and handler work:
//   - GET /fixed : 64 B fixed body.
//   - GET /json  : 1 KiB JSON built with the same field layout.
//   - POST /echo : bounded echo of the request body (Content-Length and
//     chunked both accepted by net/http), capped at 1 MiB.
//
// Logging is disabled and keep-alives are left on, matching the Mojo
// server defaults. Pin the server to one core with GOMAXPROCS=1 for the
// headline comparison, and run the load generator on separate CPUs or a
// separate host. See benchmarks/http/README.md for the full procedure.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
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
// otherwise runs from the first request byte, so a client spending most
// of the header budget would steal time from the body phase that the
// Mojo server grants separately (5s headers, then a fresh 30s body).
func withBodyDeadline(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, ok := r.Context().Value(connKey{}).(net.Conn); ok {
			// Best effort: a failed reset just leaves ReadTimeout armed.
			_ = c.SetReadDeadline(time.Now().Add(30 * time.Second))
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	addr := flag.String("addr", "127.0.0.1:18080", "listen address")
	flag.Parse()

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
		IdleTimeout:       60 * time.Second,
		ErrorLog:          log.New(io.Discard, "", 0),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, connKey{}, c)
		},
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	fmt.Printf("http_go baseline listening on %s (fixed=%dB json=%dB)\n", ln.Addr(), len(fixedBody), len(jsonBody))
	if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}
