package prediction

import (
	"testing"
	"time"
)

func TestCalculateBlendsHistory(t *testing.T) {
	wake := time.Date(2025, 7, 1, 9, 0, 0, 0, time.UTC)
	birth := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	intervals := make([]time.Duration, 7)
	for index := range intervals {
		intervals[index] = 150 * time.Minute
	}
	estimate, ok := Calculate(wake, birth, intervals, nil)
	if !ok {
		t.Fatal("expected estimate")
	}
	if got, want := estimate.Target, wake.Add(153*time.Minute); !got.Equal(want) {
		t.Fatalf("target = %v, want %v", got, want)
	}
	if estimate.Confidence != "medium" {
		t.Fatalf("confidence = %q", estimate.Confidence)
	}
}

func TestCalculateRejectsUnsupportedAge(t *testing.T) {
	wake := time.Date(2025, 7, 1, 9, 0, 0, 0, time.UTC)
	if _, ok := Calculate(wake, wake.AddDate(-3, 0, 0), nil, nil); ok {
		t.Fatal("expected no estimate")
	}
}
