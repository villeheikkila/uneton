package prediction

import (
	"fmt"
	"math"
	"sort"
	"time"
)

const AlgorithmVersion = 1

type Estimate struct {
	Target      time.Time
	RangeStart  time.Time
	RangeEnd    time.Time
	Confidence  string
	Explanation string
}

type ageRange struct{ min, max int }

func prior(ageMonths int) (ageRange, bool) {
	switch {
	case ageMonths >= 2 && ageMonths <= 3:
		return ageRange{60, 120}, true
	case ageMonths <= 5:
		return ageRange{90, 150}, true
	case ageMonths <= 8:
		return ageRange{120, 210}, true
	case ageMonths <= 12:
		return ageRange{150, 240}, true
	case ageMonths <= 18:
		return ageRange{240, 330}, true
	case ageMonths <= 24:
		return ageRange{300, 360}, true
	default:
		return ageRange{}, false
	}
}

func Calculate(wokeAt time.Time, birthDate time.Time, intervals []time.Duration, manualMinutes *int) (Estimate, bool) {
	if manualMinutes != nil {
		target := wokeAt.Add(time.Duration(*manualMinutes) * time.Minute)
		return Estimate{Target: target, RangeStart: target, RangeEnd: target, Confidence: "manual", Explanation: "Using your family reminder interval."}, true
	}
	ageMonths := (wokeAt.Year()-birthDate.Year())*12 + int(wokeAt.Month()-birthDate.Month())
	p, ok := prior(ageMonths)
	if !ok {
		return Estimate{}, false
	}
	values := make([]float64, 0, len(intervals))
	for _, interval := range intervals {
		minutes := interval.Minutes()
		if minutes >= 30 && minutes <= 720 {
			values = append(values, minutes)
		}
	}
	if len(values) > 14 {
		values = values[len(values)-14:]
	}
	values = filterOutliers(values)
	priorMid := float64(p.min+p.max) / 2
	targetMinutes := priorMid
	confidence := "low"
	explanation := "Based on the age-based starting range."
	if len(values) > 0 {
		personal := median(values)
		weight := math.Min(float64(len(values))/7, 0.8)
		targetMinutes = priorMid*(1-weight) + personal*weight
		switch {
		case len(values) >= 10:
			confidence = "high"
		case len(values) >= 4:
			confidence = "medium"
		}
		explanation = fmt.Sprintf("Based on %d recent wake periods and the age-based range.", len(values))
	}
	target := wokeAt.Add(time.Duration(math.Round(targetMinutes)) * time.Minute)
	return Estimate{
		Target:      target,
		RangeStart:  wokeAt.Add(time.Duration(p.min) * time.Minute),
		RangeEnd:    wokeAt.Add(time.Duration(p.max) * time.Minute),
		Confidence:  confidence,
		Explanation: explanation,
	}, true
}

func filterOutliers(values []float64) []float64 {
	if len(values) < 5 {
		return values
	}
	m := median(values)
	deviations := make([]float64, len(values))
	for i, value := range values {
		deviations[i] = math.Abs(value - m)
	}
	mad := median(deviations)
	if mad == 0 {
		return values
	}
	filtered := make([]float64, 0, len(values))
	for _, value := range values {
		if math.Abs(value-m)/mad <= 3.5 {
			filtered = append(filtered, value)
		}
	}
	return filtered
}

func median(values []float64) float64 {
	copyValues := append([]float64(nil), values...)
	sort.Float64s(copyValues)
	mid := len(copyValues) / 2
	if len(copyValues)%2 == 0 {
		return (copyValues[mid-1] + copyValues[mid]) / 2
	}
	return copyValues[mid]
}
