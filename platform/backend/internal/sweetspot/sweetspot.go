// Package sweetspot predicts the next likely sleep onset from a child's own
// history. It deliberately keeps inference separate from the authoritative
// sleep diary: noisy records are filtered for modelling, never rewritten.
package sweetspot

import (
	"fmt"
	"math"
	"sort"
	"time"
)

const AlgorithmVersion = 3

type Session struct {
	StartedAt           time.Time
	EndedAt             time.Time
	StartCondition      string
	SleepLocation       string
	EndCondition        string
	WakeMood            string
	WakeReason          string
	CaregiverIntervened *bool
}

type Request struct {
	WokeAt        time.Time
	BirthDate     time.Time
	Location      *time.Location
	History       []Session
	Current       *Session
	ManualMinutes *int
}

type Estimate struct {
	Target      time.Time
	RangeStart  time.Time
	RangeEnd    time.Time
	Confidence  string
	Explanation string
	Kind        string
	SampleCount int
}

// PredictWake estimates the next recorded wake boundary for an ongoing sleep.
// It conditions historical durations on the child still being asleep at now,
// so the estimate moves forward instead of becoming stale when a sleep runs long.
func PredictWake(active Session, now time.Time, location *time.Location, history []Session) (Estimate, bool) {
	if active.StartedAt.IsZero() || now.Before(active.StartedAt) {
		return Estimate{}, false
	}
	if location == nil {
		location = time.UTC
	}
	kind := sleepKind(active.StartedAt.In(location))
	elapsed := now.Sub(active.StartedAt).Minutes()
	values := make([]weightedValue, 0, len(history))
	for _, session := range normalize(history) {
		duration := session.EndedAt.Sub(session.StartedAt).Minutes()
		if duration < 5 || duration > 12*60 || sleepKind(session.StartedAt.In(location)) != kind {
			continue
		}
		ageDays := now.Sub(session.StartedAt).Hours() / 24
		if ageDays < 0 || ageDays > 120 || duration < elapsed+5 {
			continue
		}
		clockDistance := circularMinutes(session.StartedAt.In(location), active.StartedAt.In(location))
		clockWeight := clockDistance / 180
		weight := math.Exp(-math.Ln2*ageDays/28) * math.Exp(-0.5*clockWeight*clockWeight)
		if weight >= 0.025 {
			values = append(values, weightedValue{value: duration, weight: weight, observedAt: session.StartedAt})
		}
	}
	if len(values) < 3 {
		return wakeFallback(active.StartedAt, now, kind)
	}
	targetDuration := weightedQuantile(values, 0.5)
	lowDuration := weightedQuantile(values, 0.25)
	highDuration := weightedQuantile(values, 0.75)
	minimumWidth := 30.0
	if kind == "night-sleep" {
		minimumWidth = 60
	}
	if highDuration-lowDuration < minimumWidth {
		padding := (minimumWidth - (highDuration - lowDuration)) / 2
		lowDuration -= padding
		highDuration += padding
	}
	lowDuration = math.Max(lowDuration, elapsed+5)
	targetDuration = math.Max(targetDuration, lowDuration)
	highDuration = math.Max(highDuration, targetDuration+5)
	confidence := "low"
	if len(values) >= 18 && highDuration-lowDuration <= 120 {
		confidence = "high"
	} else if len(values) >= 7 {
		confidence = "medium"
	}
	return Estimate{
		Target:      active.StartedAt.Add(minutes(targetDuration)),
		RangeStart:  active.StartedAt.Add(minutes(lowDuration)),
		RangeEnd:    active.StartedAt.Add(minutes(highDuration)),
		Confidence:  confidence,
		Explanation: fmt.Sprintf("Estimated from %d similar completed sleeps; it updates while this sleep continues.", len(values)),
		Kind:        kind,
		SampleCount: len(values),
	}, true
}

type observation struct {
	wokeAt        time.Time
	minutes       float64
	priorDuration float64
	context       Session
}

func Predict(request Request) (Estimate, bool) {
	if request.WokeAt.IsZero() {
		return Estimate{}, false
	}
	if request.ManualMinutes != nil {
		target := request.WokeAt.Add(time.Duration(*request.ManualMinutes) * time.Minute)
		return Estimate{Target: target, RangeStart: target, RangeEnd: target, Confidence: "manual", Explanation: "Using your family reminder interval.", Kind: "manual"}, true
	}
	location := request.Location
	if location == nil {
		location = time.UTC
	}
	history := normalize(request.History)
	observations := transitions(history, request.WokeAt, location)
	kind := phase(request.WokeAt.In(location))
	weighted := selectSamples(observations, request.WokeAt, request.Current, kind, location)
	days := distinctObservationDays(weighted, location)
	if days < 5 {
		return fallback(request, kind)
	}

	targetMinutes := weightedQuantile(weighted, 0.5)
	lowMinutes := weightedQuantile(weighted, 0.25)
	highMinutes := weightedQuantile(weighted, 0.75)
	minimumWidth := 25.0
	if kind == "resettle" {
		minimumWidth = 35
	}
	if highMinutes-lowMinutes < minimumWidth {
		padding := (minimumWidth - (highMinutes - lowMinutes)) / 2
		lowMinutes -= padding
		highMinutes += padding
	}
	lowMinutes = math.Max(10, lowMinutes)
	if kind != "resettle" {
		if prior, ok := agePrior(request.WokeAt, request.BirthDate, kind); ok {
			personalWeight := math.Min(float64(days)/14, 0.75)
			targetMinutes = blend(prior.target(), targetMinutes, personalWeight)
			lowMinutes = blend(prior.low, lowMinutes, personalWeight)
			highMinutes = blend(prior.high, highMinutes, personalWeight)
			lowMinutes, targetMinutes, highMinutes = constrainInterval(lowMinutes, targetMinutes, highMinutes, prior.low, prior.high, minimumWidth)
		}
	}

	confidence := "low"
	if days >= 12 && len(weighted) >= 18 && highMinutes-lowMinutes <= 75 {
		confidence = "high"
	} else if days >= 7 {
		confidence = "medium"
	}
	explanation := fmt.Sprintf("Based on %d similar wake periods across %d days, blended with age-appropriate guidance.", len(weighted), days)
	if kind == "resettle" {
		explanation = fmt.Sprintf("Based on %d prior nighttime wakings across %d days; nighttime estimates are less certain because quiet wakings may not be recorded.", len(weighted), days)
	}
	return Estimate{
		Target:      request.WokeAt.Add(minutes(targetMinutes)),
		RangeStart:  request.WokeAt.Add(minutes(lowMinutes)),
		RangeEnd:    request.WokeAt.Add(minutes(highMinutes)),
		Confidence:  confidence,
		Explanation: explanation,
		Kind:        kind,
		SampleCount: len(weighted),
	}, true
}

type weightedValue struct {
	value, weight float64
	observedAt    time.Time
}

func selectSamples(values []observation, wokeAt time.Time, current *Session, kind string, location *time.Location) []weightedValue {
	result := make([]weightedValue, 0, len(values))
	for _, value := range values {
		if phase(value.wokeAt.In(location)) != kind {
			continue
		}
		ageDays := wokeAt.Sub(value.wokeAt).Hours() / 24
		if ageDays < 0 || ageDays > 120 {
			continue
		}
		clockDistance := circularMinutes(value.wokeAt.In(location), wokeAt.In(location))
		clockWeight := clockDistance / 180
		weight := math.Exp(-math.Ln2*ageDays/28) * math.Exp(-0.5*clockWeight*clockWeight)
		if current != nil {
			duration := current.EndedAt.Sub(current.StartedAt).Minutes()
			if duration > 0 && value.priorDuration > 0 {
				durationWeight := (duration - value.priorDuration) / 120
				weight *= math.Exp(-0.5 * durationWeight * durationWeight)
			}
			weight *= contextWeight(*current, value.context, values)
		}
		if weight >= 0.025 {
			result = append(result, weightedValue{value: value.minutes, weight: weight, observedAt: value.wokeAt})
		}
	}
	return result
}

func contextWeight(current, historical Session, all []observation) float64 {
	// Sparse context must not swing a prediction. Enable a match bonus only
	// after that exact field value has at least five personal observations.
	weight := fieldWeight(current.EndCondition, historical.EndCondition, all, func(value Session) string { return value.EndCondition })
	weight *= fieldWeight(current.WakeMood, historical.WakeMood, all, func(value Session) string { return value.WakeMood })
	weight *= fieldWeight(current.WakeReason, historical.WakeReason, all, func(value Session) string { return value.WakeReason })
	weight *= fieldWeight(current.SleepLocation, historical.SleepLocation, all, func(value Session) string { return value.SleepLocation })
	if current.CaregiverIntervened != nil {
		count := 0
		for _, item := range all {
			if item.context.CaregiverIntervened != nil && *item.context.CaregiverIntervened == *current.CaregiverIntervened {
				count++
			}
		}
		if count >= 5 && historical.CaregiverIntervened != nil {
			if *historical.CaregiverIntervened == *current.CaregiverIntervened {
				weight *= 1.2
			} else {
				weight *= 0.85
			}
		}
	}
	return weight
}

func fieldWeight(current, historical string, all []observation, field func(Session) string) float64 {
	if current == "" || current == "unknown" {
		return 1
	}
	count := 0
	for _, item := range all {
		if field(item.context) == current {
			count++
		}
	}
	if count < 5 {
		return 1
	}
	if historical == current {
		return 1.2
	}
	if historical != "" && historical != "unknown" {
		return 0.85
	}
	return 1
}

func transitions(history []Session, before time.Time, location *time.Location) []observation {
	result := make([]observation, 0, len(history))
	for index := 1; index < len(history); index++ {
		previous, next := history[index-1], history[index]
		if previous.EndedAt.IsZero() || !next.StartedAt.Before(before) {
			continue
		}
		gap := next.StartedAt.Sub(previous.EndedAt).Minutes()
		kind := phase(previous.EndedAt.In(location))
		maximum := 8 * 60.0
		if kind != "resettle" {
			maximum = 6 * 60
		}
		if gap < 5 || gap > maximum {
			continue
		}
		result = append(result, observation{wokeAt: previous.EndedAt, minutes: gap, priorDuration: previous.EndedAt.Sub(previous.StartedAt).Minutes(), context: previous})
	}
	return result
}

func normalize(history []Session) []Session {
	values := append([]Session(nil), history...)
	sort.SliceStable(values, func(i, j int) bool { return values[i].StartedAt.Before(values[j].StartedAt) })
	result := make([]Session, 0, len(values))
	for _, value := range values {
		if value.StartedAt.IsZero() || value.EndedAt.IsZero() || !value.EndedAt.After(value.StartedAt) {
			continue
		}
		if len(result) > 0 && !value.StartedAt.After(result[len(result)-1].EndedAt) {
			if value.EndedAt.After(result[len(result)-1].EndedAt) {
				result[len(result)-1].EndedAt = value.EndedAt
			}
			continue
		}
		result = append(result, value)
	}
	return result
}

func phase(local time.Time) string {
	minutes := local.Hour()*60 + local.Minute()
	if minutes < 6*60 || minutes >= 20*60 {
		return "resettle"
	}
	if minutes < 11*60 {
		return "morning"
	}
	if minutes < 17*60 {
		return "daytime"
	}
	return "bedtime"
}

func fallback(request Request, kind string) (Estimate, bool) {
	prior, ok := agePrior(request.WokeAt, request.BirthDate, kind)
	if !ok {
		return Estimate{}, false
	}
	target := prior.target()
	return Estimate{Target: request.WokeAt.Add(minutes(target)), RangeStart: request.WokeAt.Add(minutes(prior.low)), RangeEnd: request.WokeAt.Add(minutes(prior.high)), Confidence: "low", Explanation: "A cautious starting estimate; repeated personal history across at least five days is needed.", Kind: kind}, true
}

type intervalPrior struct{ low, high float64 }

func (value intervalPrior) target() float64 { return (value.low + value.high) / 2 }

func agePrior(wokeAt, birthDate time.Time, kind string) (intervalPrior, bool) {
	if kind == "resettle" {
		return intervalPrior{low: 15, high: 120}, true
	}
	ageMonths := (wokeAt.Year()-birthDate.Year())*12 + int(wokeAt.Month()-birthDate.Month())
	switch {
	case ageMonths >= 2 && ageMonths <= 3:
		return intervalPrior{low: 60, high: 120}, true
	case ageMonths <= 5:
		return intervalPrior{low: 90, high: 150}, true
	case ageMonths <= 8:
		return intervalPrior{low: 120, high: 210}, true
	case ageMonths <= 12:
		return intervalPrior{low: 150, high: 240}, true
	case ageMonths <= 18:
		return intervalPrior{low: 240, high: 330}, true
	case ageMonths <= 24:
		return intervalPrior{low: 300, high: 360}, true
	default:
		return intervalPrior{}, false
	}
}

func sleepKind(local time.Time) string {
	minutes := local.Hour()*60 + local.Minute()
	if minutes >= 18*60 || minutes < 6*60 {
		return "night-sleep"
	}
	return "nap"
}

func wakeFallback(startedAt, now time.Time, kind string) (Estimate, bool) {
	elapsed := now.Sub(startedAt)
	if kind == "night-sleep" {
		target := maxDuration(elapsed+30*time.Minute, 3*time.Hour)
		return Estimate{Target: startedAt.Add(target), RangeStart: now.Add(10 * time.Minute), RangeEnd: startedAt.Add(maxDuration(target+60*time.Minute, elapsed+90*time.Minute)), Confidence: "low", Explanation: "A broad nighttime estimate; more comparable completed sleeps are needed.", Kind: kind}, true
	}
	target := maxDuration(elapsed+20*time.Minute, 45*time.Minute)
	return Estimate{Target: startedAt.Add(target), RangeStart: now.Add(5 * time.Minute), RangeEnd: startedAt.Add(maxDuration(target+30*time.Minute, elapsed+50*time.Minute)), Confidence: "low", Explanation: "A broad nap estimate; more comparable completed sleeps are needed.", Kind: kind}, true
}

func maxDuration(left, right time.Duration) time.Duration {
	if left > right {
		return left
	}
	return right
}

func weightedQuantile(values []weightedValue, quantile float64) float64 {
	ordered := append([]weightedValue(nil), values...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].value < ordered[j].value })
	total := 0.0
	for _, value := range ordered {
		total += value.weight
	}
	threshold := total * quantile
	seen := 0.0
	for _, value := range ordered {
		seen += value.weight
		if seen >= threshold {
			return value.value
		}
	}
	return ordered[len(ordered)-1].value
}

func distinctObservationDays(values []weightedValue, location *time.Location) int {
	days := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value.observedAt.IsZero() {
			continue
		}
		days[value.observedAt.In(location).Format(time.DateOnly)] = struct{}{}
	}
	return len(days)
}

func blend(prior, personal, personalWeight float64) float64 {
	return prior*(1-personalWeight) + personal*personalWeight
}

func constrainInterval(low, target, high, minimum, maximum, minimumWidth float64) (float64, float64, float64) {
	target = clamp(target, minimum, maximum)
	low = clamp(low, minimum, target)
	high = clamp(high, target, maximum)
	if high-low >= minimumWidth {
		return low, target, high
	}
	low = math.Max(minimum, target-minimumWidth/2)
	high = math.Min(maximum, target+minimumWidth/2)
	if high-low < minimumWidth {
		if low == minimum {
			high = math.Min(maximum, low+minimumWidth)
		} else {
			low = math.Max(minimum, high-minimumWidth)
		}
	}
	return low, target, high
}

func clamp(value, minimum, maximum float64) float64 {
	return math.Min(math.Max(value, minimum), maximum)
}

func circularMinutes(a, b time.Time) float64 {
	difference := math.Abs(float64((a.Hour()*60 + a.Minute()) - (b.Hour()*60 + b.Minute())))
	return math.Min(difference, 1440-difference)
}

func minutes(value float64) time.Duration { return time.Duration(math.Round(value)) * time.Minute }
