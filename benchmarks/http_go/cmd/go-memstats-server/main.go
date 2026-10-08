package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"strings"
	"syscall"
	"time"
)

var fixedBody = []byte(strings.Repeat("a", 64))

func fixedHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", fmt.Sprint(len(fixedBody)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(fixedBody)
}

func memstatsHandler(w http.ResponseWriter, _ *http.Request) {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"mallocs":      m.Mallocs,
		"frees":        m.Frees,
		"total_alloc":  m.TotalAlloc,
		"heap_alloc":   m.HeapAlloc,
		"heap_objects": m.HeapObjects,
		"num_gc":       m.NumGC,
	})
}

func main() {
	addr := flag.String("addr", "127.0.0.1:19080", "listen address")
	flag.Parse()

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
	mux.HandleFunc("/_memstats", memstatsHandler)

	lc := net.ListenConfig{
		KeepAlive: -1,
	}
	ln, err := lc.Listen(context.Background(), "tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}

	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       35 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       3600 * time.Second,
	}
	fmt.Printf("go_memstats_server listening on %s\n", ln.Addr())
	if err := server.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}
