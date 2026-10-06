package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type windowJSON struct {
	StartUnixNS int64 `json:"start_unix_ns"`
	EndUnixNS   int64 `json:"end_unix_ns"`
	ElapsedNS   int64 `json:"elapsed_ns"`
}

type timingJSON struct {
	Measured *windowJSON `json:"measurement_window"`
	Warmup   *windowJSON `json:"warmup_window"`
}

func timings(t *testing.T, r result) timingJSON {
	t.Helper()
	encoded, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var got timingJSON
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func checkWindow(t *testing.T, window *windowJSON, duration time.Duration, before, after int64) {
	t.Helper()
	if window == nil {
		t.Fatal("actual phase interval is absent from JSON")
	}
	if window.StartUnixNS < before || window.EndUnixNS > after || window.EndUnixNS-window.StartUnixNS != int64(duration) || window.ElapsedNS != int64(duration) {
		t.Fatalf("phase boundaries/duration %+v outside [%d, %d], want %v", window, before, after, duration)
	}
}

func TestMeasurementWindowExcludesWarmupDrain(t *testing.T) {
	for _, rate := range []int{0, 50} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			var calls, warmupDrain atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if calls.Add(1) == 1 {
					time.Sleep(60 * time.Millisecond)
					warmupDrain.Store(time.Now().UnixNano())
				}
				fmt.Fprint(w, strings.Repeat("a", 64))
			}))
			defer server.Close()
			c := testConfig(server.URL + "/fixed")
			c.Rate, c.Warmup, c.Duration = rate, 15*time.Millisecond, 40*time.Millisecond
			before := time.Now().UnixNano()
			r, err := run(c)
			after := time.Now().UnixNano()
			if err != nil || !r.Valid || r.WarmupCounts.Success != 1 {
				t.Fatalf("controlled fixture did not complete both phases: %+v %v", r, err)
			}
			got := timings(t, r)
			checkWindow(t, got.Warmup, c.Warmup, before, after)
			checkWindow(t, got.Measured, c.Duration, before, after)
			if got.Warmup.EndUnixNS >= warmupDrain.Load() || got.Measured.StartUnixNS < warmupDrain.Load() || r.ElapsedSeconds != .04 {
				t.Fatalf("warmup/drain included in measuring interval: %+v drain=%d elapsed=%v", got, warmupDrain.Load(), r.ElapsedSeconds)
			}
		})
	}
}

func TestInvalidMeasurementRetainsWindow(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, strings.Repeat("z", 64))
	}))
	defer server.Close()
	for _, rate := range []int{0, 100} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			c := testConfig(server.URL + "/fixed")
			c.Rate = rate
			before := time.Now().UnixNano()
			r, err := run(c)
			after := time.Now().UnixNano()
			if err == nil || r.Valid {
				t.Fatalf("bad payload accepted: %+v %v", r, err)
			}
			got := timings(t, r)
			checkWindow(t, got.Measured, c.Duration, before, after)
			if got.Warmup != nil {
				t.Fatal("disabled warmup has a fabricated window")
			}
		})
	}
}

func TestAbortedMeasurementDoesNotFabricateWindow(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, strings.Repeat("z", 64))
	}))
	defer server.Close()
	for _, rate := range []int{0, 100} {
		t.Run(fmt.Sprint(rate), func(t *testing.T) {
			c := testConfig(server.URL + "/fixed")
			c.Rate, c.Warmup = rate, 15*time.Millisecond
			before := time.Now().UnixNano()
			r, err := run(c)
			after := time.Now().UnixNano()
			got := timings(t, r)
			if err == nil || got.Measured != nil {
				t.Fatalf("failed warmup fabricated measuring interval: %+v %v", got, err)
			}
			checkWindow(t, got.Warmup, c.Warmup, before, after)
		})
	}
	c := testConfig(server.URL + "/fixed")
	c.Connections = 0
	r, err := run(c)
	got := timings(t, r)
	if err == nil || got.Measured != nil || got.Warmup != nil {
		t.Fatalf("invalid configuration fabricated phase: %+v %v", got, err)
	}
}
