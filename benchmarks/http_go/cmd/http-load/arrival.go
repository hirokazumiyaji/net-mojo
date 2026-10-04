package main

import (
	"context"
	"errors"
	"math"
	"math/bits"
	"net/http"
	"sync"
	"time"
)

type arrivalStats struct {
	Scheduled        uint64       `json:"scheduled"`
	Dropped          uint64       `json:"dropped"`
	Unstarted        uint64       `json:"unstarted"`
	ServiceSamples   uint64       `json:"service_samples"`
	ServiceLatencyMS latencyStats `json:"service_latency_ms"`
	StartLagSamples  uint64       `json:"start_lag_samples"`
	StartLagP99MS    float64      `json:"start_lag_p99_ms"`
	StartLagMaxMS    float64      `json:"start_lag_max_ms"`
}

func arrivalCount(duration time.Duration, rate int) (uint64, error) {
	hi, lo := bits.Mul64(uint64(duration), uint64(rate))
	if hi >= uint64(time.Second) {
		return 0, errors.New("arrival count overflows")
	}
	n, remainder := bits.Div64(hi, lo, uint64(time.Second))
	if remainder > 0 {
		if n == math.MaxUint64 {
			return 0, errors.New("arrival count overflows")
		}
		n++
	}
	return n, nil
}

func arrivalOffset(index uint64, rate int) time.Duration {
	hi, lo := bits.Mul64(index, uint64(time.Second))
	n, _ := bits.Div64(hi, lo, uint64(rate))
	return time.Duration(n)
}

func runPhase(clients []*http.Client, c config, w workload, duration time.Duration, sample bool, observe func(time.Duration, bool) (time.Time, time.Time)) phaseResult {
	if c.Rate == 0 {
		return phase(clients, c, w, duration, sample, observe)
	}
	return arrivalPhase(clients, c, w, duration, sample, observe)
}

func arrivalPhase(clients []*http.Client, c config, w workload, duration time.Duration, sample bool, observe func(time.Duration, bool) (time.Time, time.Time)) phaseResult {
	scheduled, _ := arrivalCount(duration, c.Rate)
	jobs := make(chan time.Time, c.Connections)
	start := make(chan struct{})
	type workerResult struct {
		phaseResult
		service, lag []time.Duration
	}
	results := make(chan workerResult, c.Connections)
	var ready sync.WaitGroup
	ready.Add(c.Connections)
	var deadline time.Time
	var ctx context.Context
	for i := 0; i < c.Connections; i++ {
		client := clients[i]
		go func() {
			ready.Done()
			<-start
			var r workerResult
			for planned := range jobs {
				began := time.Now()
				if sample && !began.Before(deadline) {
					continue
				}
				r.Started++
				if sample {
					r.lag = append(r.lag, began.Sub(planned))
				}
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
						r.samples = append(r.samples, finished.Sub(planned))
						r.service = append(r.service, finished.Sub(began))
					}
				}
			}
			results <- r
		}()
	}
	ready.Wait()
	begin, end := observe(duration, sample)
	deadline = end
	var cancel context.CancelFunc
	if sample {
		ctx, cancel = context.WithDeadline(context.Background(), deadline)
	} else {
		ctx, cancel = context.WithCancel(context.Background())
	}
	defer cancel()
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	wait := func(at time.Time) bool {
		if delay := time.Until(at); delay > 0 {
			timer.Reset(delay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				return false
			}
		}
		return true
	}
	close(start)
	var dropped uint64
	for index := uint64(0); index < scheduled; index++ {
		planned := begin.Add(arrivalOffset(index, c.Rate))
		if !wait(planned) || !time.Now().Before(deadline) {
			break
		}
		select {
		case jobs <- planned:
		default:
			dropped++
		}
	}
	wait(deadline)
	close(jobs)
	total := phaseResult{window: newPhaseWindow(begin, deadline), deadline: deadline}
	var service, lag []time.Duration
	for i := 0; i < c.Connections; i++ {
		r := <-results
		total.merge(r.phaseResult)
		service = append(service, r.service...)
		lag = append(lag, r.lag...)
	}
	stats := arrivalStats{Scheduled: scheduled, Dropped: dropped,
		Unstarted: scheduled - total.Started - dropped, ServiceSamples: uint64(len(service)),
		ServiceLatencyMS: latencies(service), StartLagSamples: uint64(len(lag)), StartLagP99MS: latencies(lag).P99}
	if len(lag) > 0 {
		stats.StartLagMaxMS = float64(lag[len(lag)-1]) / float64(time.Millisecond)
	}
	total.arrivals = &stats
	return total
}

func (r *phaseResult) merge(other phaseResult) {
	r.Started += other.Started
	r.Success += other.Success
	r.Errors += other.Errors
	r.Cutoff += other.Cutoff
	r.samples = append(r.samples, other.samples...)
	if r.error == "" {
		r.error = other.error
	}
}

func (r phaseResult) lostArrivals() bool {
	return r.arrivals != nil && (r.arrivals.Dropped != 0 || r.arrivals.Unstarted != 0)
}
