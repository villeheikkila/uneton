package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestNewIDProducesDistinctUUIDs(t *testing.T) {
	first := newID()
	second := newID()
	if first == second {
		t.Fatal("generated duplicate IDs")
	}
	if len(first) != 36 || strings.Count(first, "-") != 4 {
		t.Fatalf("unexpected UUID format: %q", first)
	}
}

func TestPercentile(t *testing.T) {
	values := []time.Duration{time.Millisecond, 2 * time.Millisecond, 3 * time.Millisecond, 4 * time.Millisecond, 5 * time.Millisecond}
	if got := percentile(values, 0.50); got != 3*time.Millisecond {
		t.Fatalf("p50 = %s", got)
	}
	if got := percentile(values, 0.99); got != 5*time.Millisecond {
		t.Fatalf("p99 = %s", got)
	}
}

func TestValidateRejectsInvalidWorkload(t *testing.T) {
	if validate(config{families: 1, cycles: 1, concurrency: 1, scenariosPerWorker: 1, timeout: time.Second}) != nil {
		t.Fatal("valid workload was rejected")
	}
	if validate(config{families: 0, cycles: 1, concurrency: 1, scenariosPerWorker: 1, timeout: time.Second}) == nil {
		t.Fatal("zero families should be rejected")
	}
}

func TestConcurrencySteps(t *testing.T) {
	steps, err := concurrencySteps(config{ramp: "1, 4,16"})
	if err != nil {
		t.Fatal(err)
	}
	want := []int{1, 4, 16}
	for index := range want {
		if steps[index] != want[index] {
			t.Fatalf("steps = %v, want %v", steps, want)
		}
	}
	if _, err := concurrencySteps(config{ramp: "4,2"}); err == nil {
		t.Fatal("descending ramp should be rejected")
	}
}

func TestRecorderAggregate(t *testing.T) {
	metrics := newRecorder()
	metrics.record("Sync", time.Millisecond, nil)
	metrics.record("Sync", 3*time.Millisecond, errors.New("failed"))
	metrics.record("Auth", 2*time.Millisecond, nil)
	calls, failures, p95 := metrics.aggregate()
	if calls != 3 || failures != 1 || p95 != 3*time.Millisecond {
		t.Fatalf("aggregate = (%d, %d, %s)", calls, failures, p95)
	}
}
