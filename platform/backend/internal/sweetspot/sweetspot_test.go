package sweetspot

import (
	"testing"
	"time"
)

func TestPredictSeparatesNightResettlingFromDaytimeWakePeriods(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	start := time.Date(2026, 7, 1, 0, 0, 0, 0, location)
	var history []Session
	for day := range 12 {
		date := start.AddDate(0, 0, day)
		history = append(history,
			session(date, 0, 0, 2, 0),
			session(date, 2, 25, 5, 30),
			session(date, 7, 30, 8, 15),
			session(date, 10, 15, 11, 0),
			session(date, 13, 0, 14, 0),
		)
	}
	birth := time.Date(2026, 4, 17, 0, 0, 0, 0, location)
	nightWake := start.AddDate(0, 0, 12).Add(2 * time.Hour)
	night, ok := Predict(Request{WokeAt: nightWake, BirthDate: birth, Location: location, History: history})
	if !ok || night.Kind != "resettle" || night.Target.Sub(nightWake) > 60*time.Minute {
		t.Fatalf("night estimate = %+v, ok=%v", night, ok)
	}
	dayWake := start.AddDate(0, 0, 12).Add(8*time.Hour + 15*time.Minute)
	day, ok := Predict(Request{WokeAt: dayWake, BirthDate: birth, Location: location, History: history})
	if !ok || day.Kind != "morning" || day.Target.Sub(dayWake) < 90*time.Minute {
		t.Fatalf("day estimate = %+v, ok=%v", day, ok)
	}
}

func TestPredictDoesNotUseFutureSessions(t *testing.T) {
	now := time.Date(2026, 8, 20, 10, 0, 0, 0, time.UTC)
	history := []Session{
		{StartedAt: now.AddDate(0, 0, -2).Add(-time.Hour), EndedAt: now.AddDate(0, 0, -2)},
		{StartedAt: now.AddDate(0, 0, -2).Add(2 * time.Hour), EndedAt: now.AddDate(0, 0, -2).Add(3 * time.Hour)},
		{StartedAt: now.AddDate(0, 0, -1).Add(-time.Hour), EndedAt: now.AddDate(0, 0, -1)},
		{StartedAt: now.AddDate(0, 0, -1).Add(2 * time.Hour), EndedAt: now.AddDate(0, 0, -1).Add(3 * time.Hour)},
		{StartedAt: now.Add(24 * time.Hour), EndedAt: now.Add(25 * time.Hour)},
	}
	estimate, ok := Predict(Request{WokeAt: now, BirthDate: now.AddDate(0, -4, 0), Location: time.UTC, History: history})
	if !ok {
		t.Fatal("expected fallback estimate")
	}
	if estimate.SampleCount != 0 {
		t.Fatalf("future session leaked into sample count: %d", estimate.SampleCount)
	}
}

func TestManualPredictionIsExact(t *testing.T) {
	wokeAt := time.Date(2026, 8, 23, 7, 15, 0, 0, time.UTC)
	interval := 105
	estimate, ok := Predict(Request{WokeAt: wokeAt, ManualMinutes: &interval})
	if !ok || estimate.Target != wokeAt.Add(105*time.Minute) || estimate.Confidence != "manual" {
		t.Fatalf("estimate = %+v, ok=%v", estimate, ok)
	}
}

func TestSparseContextCannotChangeWeighting(t *testing.T) {
	values := []observation{{context: Session{WakeMood: "crying"}}}
	if got := fieldWeight("crying", "crying", values, func(value Session) string { return value.WakeMood }); got != 1 {
		t.Fatalf("sparse context weight = %v", got)
	}
	for len(values) < 5 {
		values = append(values, observation{context: Session{WakeMood: "crying"}})
	}
	if got := fieldWeight("crying", "crying", values, func(value Session) string { return value.WakeMood }); got <= 1 {
		t.Fatalf("learned context weight = %v", got)
	}
}

func TestPredictWakeConditionsOnSleepStillBeingActive(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	base := time.Date(2026, 8, 1, 12, 0, 0, 0, location)
	var history []Session
	for day := range 12 {
		start := base.AddDate(0, 0, day)
		duration := time.Duration(45+day%3*10) * time.Minute
		history = append(history, Session{StartedAt: start, EndedAt: start.Add(duration)})
	}
	activeStart := base.AddDate(0, 0, 13)
	short, ok := PredictWake(Session{StartedAt: activeStart}, activeStart.Add(10*time.Minute), location, history)
	if !ok || !short.Target.After(activeStart.Add(40*time.Minute)) {
		t.Fatalf("initial wake estimate = %+v, ok=%v", short, ok)
	}
	long, ok := PredictWake(Session{StartedAt: activeStart}, activeStart.Add(70*time.Minute), location, history)
	if !ok || !long.RangeStart.After(activeStart.Add(70*time.Minute)) {
		t.Fatalf("conditional wake estimate = %+v, ok=%v", long, ok)
	}
}

func session(day time.Time, startHour, startMinute, endHour, endMinute int) Session {
	return Session{
		StartedAt: time.Date(day.Year(), day.Month(), day.Day(), startHour, startMinute, 0, 0, day.Location()),
		EndedAt:   time.Date(day.Year(), day.Month(), day.Day(), endHour, endMinute, 0, 0, day.Location()),
	}
}
