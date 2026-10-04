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
	past := []Session{
		{StartedAt: now.AddDate(0, 0, -2).Add(-time.Hour), EndedAt: now.AddDate(0, 0, -2)},
		{StartedAt: now.AddDate(0, 0, -2).Add(2 * time.Hour), EndedAt: now.AddDate(0, 0, -2).Add(3 * time.Hour)},
		{StartedAt: now.AddDate(0, 0, -1).Add(-time.Hour), EndedAt: now.AddDate(0, 0, -1)},
		{StartedAt: now.AddDate(0, 0, -1).Add(2 * time.Hour), EndedAt: now.AddDate(0, 0, -1).Add(3 * time.Hour)},
	}
	withFuture := append(append([]Session(nil), past...), Session{StartedAt: now.Add(24 * time.Hour), EndedAt: now.Add(25 * time.Hour)})
	birth := now.AddDate(0, -4, 0)
	without, _ := Predict(Request{WokeAt: now, BirthDate: birth, Location: time.UTC, History: past})
	with, ok := Predict(Request{WokeAt: now, BirthDate: birth, Location: time.UTC, History: withFuture})
	if !ok || with != without {
		t.Fatalf("future session changed the estimate:\n%+v\n%+v", with, without)
	}
}

// dailyWindows builds days with a morning wake at 06:00 and naps separated by
// the given wake window, so every window after the morning has that length.
func dailyWindows(base time.Time, days int, window time.Duration) []Session {
	var history []Session
	for day := range days {
		date := base.AddDate(0, 0, day)
		night := time.Date(date.Year(), date.Month(), date.Day(), 6, 0, 0, 0, date.Location())
		history = append(history, Session{StartedAt: night.Add(-10 * time.Hour), EndedAt: night})
		cursor := night
		for range 2 {
			start := cursor.Add(window)
			history = append(history, Session{StartedAt: start, EndedAt: start.Add(time.Hour)})
			cursor = start.Add(time.Hour)
		}
	}
	return history
}

func TestFewDaysStayCloseToTheAgePriorAndManyDaysFollowTheChild(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	birth := time.Date(2026, 3, 1, 0, 0, 0, 0, location)
	base := time.Date(2026, 7, 1, 0, 0, 0, 0, location)
	prior, _ := agePrior(base.Sub(birth).Hours()/24, false)
	personal := 5 * time.Hour
	predict := func(days int) time.Duration {
		// Predict the first window of the next day, after its night.
		history := dailyWindows(base, days+1, personal)
		history = history[:len(history)-2]
		last := history[len(history)-1]
		estimate, ok := Predict(Request{WokeAt: last.EndedAt, BirthDate: birth, Location: location, History: history, Current: &last})
		if !ok || estimate.Coverage != NominalCoverage {
			t.Fatalf("estimate = %+v, ok=%v", estimate, ok)
		}
		return estimate.Target.Sub(last.EndedAt)
	}
	one, many := predict(1), predict(14)
	if one >= personal || one.Minutes() <= prior.target() {
		t.Fatalf("one day moved to %v; want between the prior %.0fm and the child's %v", one, prior.target(), personal)
	}
	if difference := (many - personal).Abs(); difference > 15*time.Minute {
		t.Fatalf("fourteen days predicted %v, want the child's own %v without an age cap", many, personal)
	}
}

func TestAgePriorCoversNewbornsToddlersAndHasNoMonthJumps(t *testing.T) {
	newborn, ok := agePrior(20, false)
	if !ok || newborn.high > 80 {
		t.Fatalf("newborn prior = %+v, want short wake windows", newborn)
	}
	if _, ok := agePrior(30*30, false); !ok {
		t.Fatal("no prior for a two-and-a-half-year-old")
	}
	previous, _ := agePrior(0, false)
	for day := 1.0; day <= 1460; day++ {
		current, _ := agePrior(day, false)
		if current.target() < previous.target() || current.target()-previous.target() > 2 {
			t.Fatalf("prior jumps at day %.0f: %.1f -> %.1f", day, previous.target(), current.target())
		}
		previous = current
	}
}

func TestEarlyMorningNapIsNotPartOfTheNight(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	day := time.Date(2026, 7, 2, 0, 0, 0, 0, location)
	labels := label([]Session{
		session(day.AddDate(0, 0, -1), 20, 0, 23, 30),
		session(day, 0, 10, 6, 0),
		session(day, 7, 30, 8, 15),
		session(day, 10, 30, 11, 30),
	}, location)
	if !labels[1].nightEnd || labels[2].night || labels[2].napIndex != 1 || labels[3].napIndex != 2 {
		t.Fatalf("labels = %+v", labels)
	}
}

func TestNapTransitionIsReported(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	birth := time.Date(2025, 9, 1, 0, 0, 0, 0, location)
	base := time.Date(2026, 7, 1, 0, 0, 0, 0, location)
	history := dailyWindows(base, 10, 3*time.Hour)
	for day := 10; day < 16; day++ {
		date := base.AddDate(0, 0, day)
		morning := time.Date(date.Year(), date.Month(), date.Day(), 6, 0, 0, 0, location)
		history = append(history,
			Session{StartedAt: morning.Add(-10 * time.Hour), EndedAt: morning},
			Session{StartedAt: morning.Add(5 * time.Hour), EndedAt: morning.Add(7 * time.Hour)})
	}
	last := history[len(history)-1]
	estimate, ok := Predict(Request{WokeAt: last.EndedAt, BirthDate: birth, Location: location, History: history, Current: &last})
	if !ok || estimate.TypicalNaps != 1 || !estimate.NapTransition {
		t.Fatalf("estimate = %+v, want one nap and a transition", estimate)
	}
}

func TestNightWakePredictsTheMorning(t *testing.T) {
	location := time.FixedZone("EEST", 3*60*60)
	base := time.Date(2026, 7, 1, 0, 0, 0, 0, location)
	history := dailyWindows(base, 10, 2*time.Hour)
	night := time.Date(2026, 7, 10, 20, 0, 0, 0, location)
	estimate, ok := PredictWake(Session{StartedAt: night}, night.Add(30*time.Minute), location, history)
	if !ok || estimate.Kind != "morning-wake" || estimate.Target.In(location).Hour() != 6 {
		t.Fatalf("estimate = %+v, want a morning wake around 06:00", estimate)
	}
	late, ok := PredictWake(Session{StartedAt: night}, night.Add(11*time.Hour), location, history)
	if !ok || !late.RangeStart.After(night.Add(11*time.Hour)) {
		t.Fatalf("estimate past the usual morning = %+v", late)
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
