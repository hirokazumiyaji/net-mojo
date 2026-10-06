package main

import (
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestExactArrivalScheduleAndOverflow(t *testing.T) {
	for _, tc := range []struct {
		duration time.Duration
		rate     int
		want     uint64
	}{
		{time.Second, 3, 3}, {333333333, 3, 1}, {333333334, 3, 2},
		{time.Nanosecond, math.MaxInt, 9223372037},
	} {
		n, err := arrivalCount(tc.duration, tc.rate)
		if err != nil || n != tc.want {
			t.Fatalf("schedule %+v: count=%d err=%v", tc, n, err)
		}
	}
	for i, want := range []time.Duration{0, 333333333, 666666666} {
		if got := arrivalOffset(uint64(i), 3); got != want {
			t.Fatalf("arrival %d: %v != %v", i, got, want)
		}
	}
	if _, err := arrivalCount(time.Duration(math.MaxInt64), math.MaxInt); err == nil {
		t.Fatal("overflow schedule accepted")
	}
	c := testConfig("http://localhost/fixed")
	c.Rate = -1
	if _, err := run(c); err == nil {
		t.Fatal("negative rate accepted")
	}
}

func TestFixedArrivalBelowCapacityAccountsEveryArrival(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, strings.Repeat("a", 64)) }))
	defer server.Close()
	c := testConfig(server.URL + "/fixed")
	c.Rate, c.Duration = 10, 220*time.Millisecond
	r, err := run(c)
	if err != nil || !r.Valid || r.Success != 3 || r.Samples != 3 || r.Arrivals.Scheduled != 3 || r.Arrivals.Dropped != 0 || r.Arrivals.Unstarted != 0 || r.Arrivals.StartLagSamples != 3 {
		t.Fatalf("fixed arrivals lost/invalid: %+v arrivals=%+v err=%v", r, r.Arrivals, err)
	}
	if r.ElapsedSeconds != .22 || r.RequestsPerSecond != 3/.22 {
		t.Fatalf("fixed window rate: %+v", r)
	}
}

func TestFixedArrivalOverloadReportsLossAndScheduledLatency(t *testing.T) {
	var active, maximum atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := active.Add(1)
		if n > maximum.Load() {
			maximum.Store(n)
		}
		defer active.Add(-1)
		time.Sleep(15 * time.Millisecond)
		fmt.Fprint(w, strings.Repeat("a", 64))
	}))
	defer server.Close()
	c := testConfig(server.URL + "/fixed")
	c.Rate, c.Duration = 100, 90*time.Millisecond
	r, err := run(c)
	if err == nil || r.Valid || r.Arrivals.Dropped == 0 || r.Success < 2 || maximum.Load() != 1 {
		t.Fatalf("overload hidden/unbounded: %+v arrivals=%+v max=%d err=%v", r, r.Arrivals, maximum.Load(), err)
	}
	if r.Arrivals.Scheduled != r.Started+r.Arrivals.Dropped+r.Arrivals.Unstarted || r.Started != r.Success+r.Errors+r.Cutoff || r.Samples != r.Success {
		t.Fatalf("unaccounted arrival: %+v %+v", r, r.Arrivals)
	}
	if r.LatencyMS.P50 <= r.Arrivals.ServiceLatencyMS.P50+2 || r.Arrivals.StartLagP99MS < 2 || r.Arrivals.StartLagSamples != r.Started {
		t.Fatalf("queue wait omitted: total=%+v arrivals=%+v", r.LatencyMS, r.Arrivals)
	}
	c.Warmup = 90 * time.Millisecond
	r, err = run(c)
	if err == nil || r.Started != 0 || r.WarmupArrivals.Dropped == 0 {
		t.Fatalf("overloaded warmup measured: %+v warmup=%+v %v", r, r.WarmupArrivals, err)
	}
}

func TestFixedArrivalUnstartedWorkIsNotOmitted(t *testing.T) {
	c := testConfig("http://localhost/fixed")
	c.Rate, c.Duration = 1000, time.Nanosecond
	r, err := run(c)
	if err == nil || r.Valid || r.Started != 0 || r.Arrivals.Scheduled != 1 || r.Arrivals.Unstarted != 1 {
		t.Fatalf("missed arrival hidden: %+v arrivals=%+v %v", r, r.Arrivals, err)
	}
}

func TestFixedArrivalWarmupValidatesLateDrain(t *testing.T) {
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
	c.Rate, c.Warmup = 50, 30*time.Millisecond
	r, err := run(c)
	if err == nil || r.Started != 0 || r.WarmupCounts.Success != 1 || r.WarmupCounts.Errors != 1 || r.WarmupCounts.Cutoff != 0 || r.WarmupArrivals.Unstarted != 0 {
		t.Fatalf("late warmup invalid response hidden: %+v arrivals=%+v %v", r, r.WarmupArrivals, err)
	}
}

func TestFixedArrivalDelayedDispatcherPhaseBoundary(t *testing.T) {
	for _, tc := range []struct {
		name      string
		sample    bool
		started   uint64
		unstarted uint64
	}{
		{"warmup_drains_all_planned_slots", false, 3, 0},
		{"measurement_preserves_cutoff", true, 0, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Uint64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				fmt.Fprint(w, strings.Repeat("a", 64))
			}))
			defer server.Close()
			c := testConfig(server.URL + "/fixed")
			c.Rate, c.Connections = 1000, 3
			work, err := prepare(c)
			if err != nil {
				t.Fatal(err)
			}
			clients := []*http.Client{server.Client(), server.Client(), server.Client()}
			const duration = 3 * time.Millisecond
			var end time.Time
			observe := func(d time.Duration, _ bool) (time.Time, time.Time) {
				begin := time.Now().Add(-d - time.Millisecond)
				end = begin.Add(d)
				return begin, end
			}
			r := arrivalPhase(clients, c, work, duration, tc.sample, observe)
			if r.Started != tc.started || r.Success != tc.started || r.Errors != 0 || r.Cutoff != 0 || calls.Load() != tc.started {
				t.Fatalf("delayed phase request accounting: %+v calls=%d", r, calls.Load())
			}
			if r.arrivals.Scheduled != 3 || r.arrivals.Dropped != 0 || r.arrivals.Unstarted != tc.unstarted || r.lostArrivals() != tc.sample {
				t.Fatalf("planned slots omitted or cutoff hidden: %+v", r.arrivals)
			}
			if len(r.samples) != 0 || r.arrivals.ServiceSamples != 0 || r.arrivals.StartLagSamples != 0 || r.window.ElapsedNS != int64(duration) || r.window.EndUnixNS != end.UnixNano() {
				t.Fatalf("late work changed the nominal interval or measured samples: %+v", r)
			}
		})
	}
}
