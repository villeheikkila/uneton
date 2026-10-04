// Package sweetspot predicts the next likely sleep onset from a child's own
// history. It deliberately keeps inference separate from the authoritative
// sleep diary: noisy records are filtered for modelling, never rewritten.
//
// Version 4 reads the child's own day structure (night, morning wake, nap
// number), models how each wake window grows with age instead of averaging over
// that growth, shrinks toward an age prior only as far as personal evidence is
// thin, and sizes its range from the child's own errors so the stated coverage
// is measurable.
package sweetspot

import (
	"fmt"
	"math"
	"sort"
	"time"
)

const AlgorithmVersion = 4

// NominalCoverage is the share of outcomes an estimate's range aims to contain.
const NominalCoverage = 0.8

// z80 is the standard normal quantile bounding a central 80% interval.
const z80 = 1.2815515655446004

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
	// Coverage is the probability the range claims to contain the outcome.
	Coverage float64
	// TypicalNaps is the median number of naps on recent complete days, and
	// NapTransition reports that it differs from the days before them.
	TypicalNaps   int
	NapTransition bool
}

// Night segments start in this coarse local window and chain while the gaps
// between them stay short. Everything else is a nap.
const (
	nightStartFromHour  = 18
	nightStartToHour    = 4
	nightChainGap       = 3 * time.Hour
	nightContinueToHour = 6
	morningFromHour     = 4
	morningToHour       = 12
)

type labeled struct {
	Session
	night    bool
	nightEnd bool // last segment of a night: the morning wake
	napIndex int  // 1-based nap number since the morning wake
}

// label classifies a sorted, normalized history. The final night segment's
// morning status depends on the future, so callers decide it for the last
// element with the child's morning anchor.
func label(history []Session, location *time.Location) []labeled {
	result := make([]labeled, len(history))
	for index, session := range history {
		result[index].Session = session
	}
	for index := 0; index < len(result); index++ {
		if result[index].night || !inNightStartWindow(result[index].StartedAt.In(location)) {
			continue
		}
		last := index
		result[index].night = true
		for next := index + 1; next < len(result); next++ {
			if result[next].StartedAt.Sub(result[last].EndedAt) > nightChainGap || !continuesNight(result[next].StartedAt.In(location)) {
				break
			}
			result[next].night = true
			last = next
		}
		if hour := result[last].EndedAt.In(location).Hour(); hour >= morningFromHour && hour < morningToHour {
			result[last].nightEnd = true
		}
		index = last
	}
	napIndex := 0
	for index := range result {
		if result[index].night {
			if result[index].nightEnd {
				napIndex = 0
			}
			continue
		}
		napIndex++
		result[index].napIndex = napIndex
	}
	return result
}

func inNightStartWindow(local time.Time) bool {
	hour := local.Hour()
	return hour >= nightStartFromHour || hour < nightStartToHour
}

// continuesNight is a start that can resume the night after a waking. After
// six in the morning a new sleep is a nap, however short the gap: otherwise an
// early morning nap would be read as part of the night.
func continuesNight(local time.Time) bool {
	hour := local.Hour()
	return hour >= nightStartFromHour || hour < nightContinueToHour
}

// structure is the child's recent rhythm: when mornings start and how many naps
// a day holds.
type structure struct {
	morningMinutes float64 // local minutes after midnight
	mornings       int
	typicalNaps    int
	transition     bool
}

func dayStructure(labels []labeled, before time.Time, location *time.Location) structure {
	result := structure{morningMinutes: 6*60 + 30}
	var mornings []weightedValue
	var napCounts []int // complete days, oldest first
	dayNaps, inDay := 0, false
	for _, item := range labels {
		if !item.EndedAt.Before(before) {
			break
		}
		if item.nightEnd {
			if inDay {
				napCounts = append(napCounts, dayNaps)
			}
			dayNaps, inDay = 0, true
			ageDays := before.Sub(item.EndedAt).Hours() / 24
			if ageDays <= 14 {
				local := item.EndedAt.In(location)
				mornings = append(mornings, weightedValue{value: float64(local.Hour()*60 + local.Minute()), weight: 1, observedAt: item.EndedAt})
			}
			continue
		}
		if !item.night && inDay {
			dayNaps++
		}
	}
	if len(mornings) >= 3 {
		result.morningMinutes = weightedQuantile(mornings, 0.5)
		result.mornings = len(mornings)
	}
	recent := lastN(napCounts, 5)
	earlier := lastN(napCounts[:max(0, len(napCounts)-len(recent))], 9)
	if len(recent) >= 3 {
		result.typicalNaps = medianInt(recent)
		if len(earlier) >= 3 && medianInt(earlier) != result.typicalNaps {
			result.transition = true
		}
	}
	return result
}

// window identifies which wake period an observation or prediction belongs to:
// a nighttime resettle, or the wake window after the morning (index 0) or after
// nap n (index n).
type window struct {
	night bool
	index int
}

func (value window) kind() string {
	if value.night {
		return "resettle"
	}
	if value.index == 0 {
		return "morning"
	}
	return "daytime"
}

type observation struct {
	window        window
	wokeAt        time.Time
	minutes       float64
	priorDuration float64
	context       Session
}

func observations(labels []labeled, before time.Time) []observation {
	result := make([]observation, 0, len(labels))
	for index := 0; index+1 < len(labels); index++ {
		previous, next := labels[index], labels[index+1]
		if !next.StartedAt.Before(before) {
			break
		}
		gap := next.StartedAt.Sub(previous.EndedAt).Minutes()
		var value window
		switch {
		case previous.night && !previous.nightEnd:
			if !next.night {
				continue // the night ended without a recorded morning
			}
			value = window{night: true}
		case previous.nightEnd:
			value = window{index: 0}
		default:
			value = window{index: previous.napIndex}
		}
		maximum := 6 * 60.0
		if value.night {
			maximum = 3 * 60
		}
		if gap < 5 || gap > maximum {
			continue
		}
		result = append(result, observation{window: value, wokeAt: previous.EndedAt, minutes: gap, priorDuration: previous.EndedAt.Sub(previous.StartedAt).Minutes(), context: previous.Session})
	}
	return result
}

// currentWindow classifies the wake that just happened, before the future can
// say whether the night continues: a night segment ending well before the
// child's usual morning is a resettle.
func currentWindow(labels []labeled, wokeAt time.Time, morning structure, location *time.Location) window {
	local := wokeAt.In(location)
	hour := local.Hour()
	minutesOfDay := float64(hour*60 + local.Minute())
	nightOver := hour >= morningFromHour && hour < morningToHour && minutesOfDay >= morning.morningMinutes-45
	var last *labeled
	if len(labels) > 0 && labels[len(labels)-1].EndedAt.Sub(wokeAt).Abs() <= time.Minute {
		last = &labels[len(labels)-1]
	}
	switch {
	case last != nil && !last.night:
		return window{index: last.napIndex}
	case last != nil || continuesNight(local) || hour < morningToHour:
		// A night segment, or no recorded sleep ends here and the clock decides.
		if nightOver || (last == nil && hour >= nightContinueToHour && hour < morningToHour) {
			return window{index: 0}
		}
		if last == nil && hour >= nightStartFromHour {
			return window{index: napsSinceMorning(labels)}
		}
		return window{night: true}
	default:
		return window{index: napsSinceMorning(labels)}
	}
}

// napsSinceMorning counts naps after the latest recorded morning wake.
func napsSinceMorning(labels []labeled) int {
	for index := len(labels) - 1; index >= 0; index-- {
		if labels[index].nightEnd {
			return 0
		}
		if !labels[index].night {
			return labels[index].napIndex
		}
	}
	return 0
}

func containsStart(history []Session, start time.Time) bool {
	for _, session := range history {
		if session.StartedAt.Equal(start) {
			return true
		}
	}
	return false
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
	history := request.History
	// The sleep that just ended (or is predicted to end, for an active sleep)
	// decides which window comes next, even when the caller keeps it apart.
	if request.Current != nil && !request.Current.EndedAt.IsZero() && !containsStart(history, request.Current.StartedAt) {
		history = append(append([]Session(nil), history...), *request.Current)
	}
	history = normalize(history)
	labels := label(history, location)
	rhythm := dayStructure(labels, request.WokeAt.Add(time.Second), location)
	current := currentWindow(labelsThrough(labels, request.WokeAt), request.WokeAt, rhythm, location)
	ageDays := request.WokeAt.Sub(request.BirthDate).Hours() / 24
	prior, ok := agePrior(ageDays, current.night)
	if !ok {
		return Estimate{}, false
	}
	samples := selectSamples(observations(labels, request.WokeAt), request, current, ageDays, location)
	fit := fitLog(samples, ageDays, prior)
	estimate := fit.estimate(request.WokeAt, minimumWidth(current))
	estimate.Kind = current.kind()
	estimate.SampleCount = len(samples)
	estimate.TypicalNaps = rhythm.typicalNaps
	estimate.NapTransition = rhythm.transition
	estimate.Explanation = explanation(current, fit, rhythm)
	return estimate, true
}

// labelsThrough drops sessions starting at or after the wake being predicted.
func labelsThrough(labels []labeled, wokeAt time.Time) []labeled {
	end := len(labels)
	for end > 0 && labels[end-1].StartedAt.After(wokeAt) {
		end--
	}
	return labels[:end]
}

func minimumWidth(current window) float64 {
	if current.night {
		return 20
	}
	return 15
}

type weightedValue struct {
	value, weight float64
	observedAt    time.Time
	ageDays       float64
}

// halfLife is the recency weighting. Faster decay for young infants did not
// improve backtests; the age trend in fitLog follows development instead.
const halfLife = 28.0

func selectSamples(values []observation, request Request, current window, ageDays float64, location *time.Location) []weightedValue {
	life := halfLife
	result := make([]weightedValue, 0, len(values))
	for _, value := range values {
		if value.window.night != current.night {
			continue
		}
		// Clock time carries the circadian signal; the nap number refines it
		// once the day has a stable structure, and is otherwise only a hint.
		weight := 1.0
		if !current.night && value.window.index != current.index {
			weight = 0.5
		}
		distance := circularMinutes(value.wokeAt.In(location), request.WokeAt.In(location)) / 180
		weight *= math.Exp(-0.5 * distance * distance)
		elapsedDays := request.WokeAt.Sub(value.wokeAt).Hours() / 24
		if elapsedDays < 0 || elapsedDays > 4*life {
			continue
		}
		weight *= math.Exp(-math.Ln2 * elapsedDays / life)
		if request.Current != nil {
			duration := request.Current.EndedAt.Sub(request.Current.StartedAt).Minutes()
			if duration > 0 && value.priorDuration > 0 {
				durationWeight := (duration - value.priorDuration) / 120
				weight *= math.Exp(-0.5 * durationWeight * durationWeight)
			}
			weight *= contextWeight(*request.Current, value.context, values)
		}
		if weight >= 0.02 {
			result = append(result, weightedValue{value: value.minutes, weight: weight, observedAt: value.wokeAt, ageDays: ageDays - elapsedDays})
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

// logFit is a predictive distribution for a duration in log-minutes: a
// posterior centre and the offsets of its 10% and 90% quantiles.
type logFit struct {
	centre, lowOffset, highOffset float64
	effective                     float64
	personal                      bool
}

// calibration widens intervals uniformly; set from chronological backtests so
// that NominalCoverage holds on real diaries (see docs/sweetspot.md).
const calibration = 1.3

// napCalibration plays the same role for nap-end ranges, which are empirical
// quantiles of recent naps rather than residuals of a fitted trend.
const napCalibration = 1.05

// fitLog models log(minutes) as a weighted linear trend in age, evaluated at
// the current age, shrunk toward the age prior in proportion to the evidence.
// Interval offsets come from the fit's own residuals, blended with the prior's
// spread while the effective sample size is small.
func fitLog(samples []weightedValue, ageDays float64, prior intervalPrior) logFit {
	priorCentre := math.Log(prior.target())
	priorSpread := math.Log(prior.high/prior.low) / (2 * z80)
	result := logFit{centre: priorCentre, lowOffset: -z80 * priorSpread, highOffset: z80 * priorSpread}
	if len(samples) == 0 {
		return result
	}
	values := make([]float64, len(samples))
	weights := make([]float64, len(samples))
	for index, sample := range samples {
		values[index] = math.Log(math.Max(sample.value, 1))
		weights[index] = sample.weight
	}
	// Trim gross outliers (a missed nap doubles a window) before fitting.
	centre := weightedQuantileOf(values, weights, 0.5)
	deviations := make([]float64, len(values))
	for index, value := range values {
		deviations[index] = math.Abs(value - centre)
	}
	scale := 1.4826 * weightedQuantileOf(deviations, weights, 0.5)
	if scale > 0 {
		for index := range values {
			if deviations[index] > 3*scale {
				weights[index] = 0
			}
		}
	}
	effective := effectiveCount(weights)
	if effective < 1 {
		return result
	}
	intercept, slope := weightedTrend(values, weights, samples, ageDays)
	residuals := make([]float64, len(values))
	for index, value := range values {
		residuals[index] = value - (intercept + slope*(samples[index].ageDays-ageDays))
	}
	// Pool the observed spread with the prior's over a few pseudo-observations,
	// so a handful of near-identical windows cannot claim near certainty.
	const pseudo = 3.0
	pooled := (weightedVariance(residuals, weights)*effective + priorSpread*priorSpread*pseudo) / (effective + pseudo)
	spread := math.Sqrt(pooled)
	standardError := spread / math.Sqrt(effective)
	posterior := (intercept/(standardError*standardError) + priorCentre/(priorSpread*priorSpread)) /
		(1/(standardError*standardError) + 1/(priorSpread*priorSpread))
	share := effective / (effective + 4)
	inflation := math.Sqrt(1+1/effective) * calibration
	lowResidual := weightedQuantileOf(residuals, weights, 0.1)
	highResidual := weightedQuantileOf(residuals, weights, 0.9)
	return logFit{
		centre:     posterior,
		lowOffset:  (share*lowResidual - (1-share)*z80*priorSpread) * inflation,
		highOffset: (share*highResidual + (1-share)*z80*priorSpread) * inflation,
		effective:  effective,
		personal:   effective >= 3,
	}
}

// weightedTrend fits value = intercept + slope*(age - now). A slope needs a
// week of age spread; growth is capped at doubling per month either way.
func weightedTrend(values, weights []float64, samples []weightedValue, ageDays float64) (float64, float64) {
	sum, sumX, sumY, sumXX, sumXY := 0.0, 0.0, 0.0, 0.0, 0.0
	minimum, maximum := math.Inf(1), math.Inf(-1)
	for index, value := range values {
		weight := weights[index]
		if weight == 0 {
			continue
		}
		x := samples[index].ageDays - ageDays
		minimum, maximum = math.Min(minimum, x), math.Max(maximum, x)
		sum += weight
		sumX += weight * x
		sumY += weight * value
		sumXX += weight * x * x
		sumXY += weight * x * value
	}
	meanY := sumY / sum
	if maximum-minimum < 7 || effectiveCount(weights) < 8 {
		return weightedQuantileOf(values, weights, 0.5), 0
	}
	meanX := sumX / sum
	variance := sumXX/sum - meanX*meanX
	if variance <= 0 {
		return meanY, 0
	}
	slope := clamp((sumXY/sum-meanX*meanY)/variance, -math.Ln2/30, math.Ln2/30)
	// A median centre is robust to the long tail of missed or merged entries.
	detrended := make([]float64, len(values))
	for index, value := range values {
		detrended[index] = value - slope*(samples[index].ageDays-ageDays)
	}
	return weightedQuantileOf(detrended, weights, 0.5), slope
}

func (fit logFit) estimate(wokeAt time.Time, minimumWidth float64) Estimate {
	target := math.Exp(fit.centre)
	low := math.Max(5, math.Exp(fit.centre+fit.lowOffset))
	high := math.Exp(fit.centre + fit.highOffset)
	if high-low < minimumWidth {
		padding := (minimumWidth - (high - low)) / 2
		low, high = math.Max(5, low-padding), high+padding
	}
	target = clamp(target, low, high)
	return Estimate{
		Target:     wokeAt.Add(minutes(target)),
		RangeStart: wokeAt.Add(minutes(low)),
		RangeEnd:   wokeAt.Add(minutes(high)),
		Confidence: confidence(high-low, fit.effective),
		Coverage:   NominalCoverage,
	}
}

// confidence describes the measured spread, not just how much data exists.
func confidence(width, effective float64) string {
	switch {
	case width <= 50 && effective >= 8:
		return "high"
	case width <= 100 && effective >= 4:
		return "medium"
	default:
		return "low"
	}
}

func explanation(current window, fit logFit, rhythm structure) string {
	if !fit.personal {
		return "A cautious starting estimate from typical ranges for this age; it adapts as more days are logged."
	}
	coverage := "About 8 in 10 times the next sleep has started within this window."
	switch {
	case current.night:
		return "Based on this child's recent nighttime wakings; quiet wakings are often unrecorded, so night estimates are less certain. " + coverage
	case current.index == 0:
		return "Based on this child's recent first wake window of the day, following how it lengthens with age. " + coverage
	case rhythm.transition:
		return fmt.Sprintf("Based on recent wake windows after nap %d. Nap count is changing, so expect more variation. %s", current.index, coverage)
	default:
		return fmt.Sprintf("Based on this child's recent wake windows after nap %d, following how they lengthen with age. %s", current.index, coverage)
	}
}

type intervalPrior struct{ low, high float64 }

func (value intervalPrior) target() float64 { return math.Sqrt(value.low * value.high) }

// Age prior anchors in days and wake-window minutes (an 80% band). Typical
// ranges only: wide normal variation is expected, so personal history replaces
// this as soon as it is informative. Values between anchors are interpolated
// geometrically, so the prior has no month-boundary jumps.
var priorAnchors = []struct {
	ageDays   float64
	low, high float64
}{
	{0, 30, 70},
	{30, 40, 80},
	{60, 50, 100},
	{90, 65, 125},
	{135, 85, 150},
	{200, 110, 200},
	{300, 140, 240},
	{420, 210, 330},
	{600, 270, 370},
	{900, 300, 420},
	{1460, 330, 480},
}

func agePrior(ageDays float64, night bool) (intervalPrior, bool) {
	if night {
		return intervalPrior{low: 15, high: 120}, true
	}
	if ageDays < 0 || ageDays > 6*365 {
		return intervalPrior{}, false
	}
	anchors := priorAnchors
	if ageDays >= anchors[len(anchors)-1].ageDays {
		last := anchors[len(anchors)-1]
		return intervalPrior{low: last.low, high: last.high}, true
	}
	for index := 1; index < len(anchors); index++ {
		left, right := anchors[index-1], anchors[index]
		if ageDays <= right.ageDays {
			share := (ageDays - left.ageDays) / (right.ageDays - left.ageDays)
			return intervalPrior{
				low:  math.Exp(math.Log(left.low) + share*(math.Log(right.low)-math.Log(left.low))),
				high: math.Exp(math.Log(left.high) + share*(math.Log(right.high)-math.Log(left.high))),
			}, true
		}
	}
	return intervalPrior{}, false
}

// PredictWake estimates when an ongoing sleep ends. For a night it predicts the
// morning wake as a clock time anchored on the child's recent mornings, since
// individual night segments are split by wakings that diaries often miss. For a
// nap it uses recent naps with the same number, conditioned on the child still
// being asleep now.
func PredictWake(active Session, now time.Time, location *time.Location, history []Session) (Estimate, bool) {
	if active.StartedAt.IsZero() || now.Before(active.StartedAt) {
		return Estimate{}, false
	}
	if location == nil {
		location = time.UTC
	}
	normalized := normalize(history)
	labels := label(normalized, location)
	before := labelsThrough(labels, active.StartedAt.Add(-time.Second))
	night := inNightStartWindow(active.StartedAt.In(location))
	if !night && len(before) > 0 {
		previous := before[len(before)-1]
		if previous.night && !previous.nightEnd && active.StartedAt.Sub(previous.EndedAt) <= nightChainGap && continuesNight(active.StartedAt.In(location)) {
			night = true
		}
	}
	if night {
		return predictMorning(labels, active, now, location)
	}
	return predictNap(labels, before, active, now)
}

func predictMorning(labels []labeled, active Session, now time.Time, location *time.Location) (Estimate, bool) {
	var samples []weightedValue
	for _, item := range labels {
		if !item.nightEnd || !item.EndedAt.Before(active.StartedAt) {
			continue
		}
		elapsedDays := now.Sub(item.EndedAt).Hours() / 24
		if elapsedDays > 28 {
			continue
		}
		local := item.EndedAt.In(location)
		samples = append(samples, weightedValue{value: float64(local.Hour()*60 + local.Minute()), weight: math.Exp(-math.Ln2 * elapsedDays / 10), observedAt: item.EndedAt})
	}
	// The morning is the first matching clock time after the start.
	localStart := active.StartedAt.In(location)
	day := time.Date(localStart.Year(), localStart.Month(), localStart.Day(), 0, 0, 0, 0, location)
	if localStart.Hour() >= nightStartFromHour {
		day = day.AddDate(0, 0, 1)
	}
	at := func(minutesOfDay float64) time.Time { return day.Add(minutes(minutesOfDay)) }
	centre, low, high := 390.0, 330.0, 450.0
	confidenceLabel := "low"
	if len(samples) >= 3 {
		values, weights := split(samples)
		effective := effectiveCount(weights)
		centre = weightedQuantileOf(values, weights, 0.5)
		share := effective / (effective + 4)
		inflation := math.Sqrt(1+1/effective) * calibration
		low = centre + (share*(weightedQuantileOf(values, weights, 0.1)-centre)-(1-share)*60)*inflation
		high = centre + (share*(weightedQuantileOf(values, weights, 0.9)-centre)+(1-share)*60)*inflation
		confidenceLabel = confidence(high-low, effective)
	}
	target, rangeStart, rangeEnd := at(centre), at(low), at(high)
	// Still asleep past the usual morning: move the estimate forward.
	if !rangeStart.After(now) {
		rangeStart = now.Add(5 * time.Minute)
	}
	if !target.After(rangeStart) {
		target = rangeStart.Add(10 * time.Minute)
	}
	if !rangeEnd.After(target) {
		rangeEnd = target.Add(45 * time.Minute)
	}
	return Estimate{
		Target: target, RangeStart: rangeStart, RangeEnd: rangeEnd,
		Confidence: confidenceLabel, Coverage: NominalCoverage, Kind: "morning-wake", SampleCount: len(samples),
		Explanation: "Based on this child's recent morning wake times; it moves later while the night continues.",
	}, true
}

func predictNap(labels, before []labeled, active Session, now time.Time) (Estimate, bool) {
	napIndex := 1
	if len(before) > 0 && !before[len(before)-1].night {
		napIndex = before[len(before)-1].napIndex + 1
	}
	elapsed := now.Sub(active.StartedAt).Minutes()
	var samples []weightedValue
	for _, item := range labels {
		if item.night || !item.StartedAt.Before(active.StartedAt) || item.napIndex == 0 {
			continue
		}
		duration := item.EndedAt.Sub(item.StartedAt).Minutes()
		elapsedDays := now.Sub(item.StartedAt).Hours() / 24
		if duration < 5 || duration > 6*60 || duration < elapsed+5 || elapsedDays > 28 {
			continue
		}
		weight := math.Exp(-math.Ln2 * elapsedDays / 14)
		if item.napIndex != napIndex {
			weight *= 0.35
		}
		samples = append(samples, weightedValue{value: duration, weight: weight, observedAt: item.StartedAt})
	}
	if len(samples) < 3 {
		target := math.Max(elapsed+20, 45)
		return Estimate{
			Target:      active.StartedAt.Add(minutes(target)),
			RangeStart:  now.Add(5 * time.Minute),
			RangeEnd:    active.StartedAt.Add(minutes(math.Max(target+30, elapsed+50))),
			Confidence:  "low",
			Coverage:    NominalCoverage,
			Kind:        "nap",
			Explanation: "A broad nap estimate; more comparable completed naps are needed.",
		}, true
	}
	values, weights := split(samples)
	effective := effectiveCount(weights)
	centre := weightedQuantileOf(values, weights, 0.5)
	low := math.Max(elapsed+5, centre-(centre-weightedQuantileOf(values, weights, 0.1))*napCalibration)
	high := math.Max(low+15, centre+(weightedQuantileOf(values, weights, 0.9)-centre)*napCalibration)
	centre = clamp(centre, low, high)
	return Estimate{
		Target:      active.StartedAt.Add(minutes(centre)),
		RangeStart:  active.StartedAt.Add(minutes(low)),
		RangeEnd:    active.StartedAt.Add(minutes(high)),
		Confidence:  confidence(high-low, effective),
		Coverage:    NominalCoverage,
		Kind:        "nap",
		SampleCount: len(samples),
		Explanation: fmt.Sprintf("Based on %d recent naps like this one; it updates while the nap continues.", len(samples)),
	}, true
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

func split(samples []weightedValue) ([]float64, []float64) {
	values := make([]float64, len(samples))
	weights := make([]float64, len(samples))
	for index, sample := range samples {
		values[index], weights[index] = sample.value, sample.weight
	}
	return values, weights
}

func weightedQuantile(values []weightedValue, quantile float64) float64 {
	numbers, weights := split(values)
	return weightedQuantileOf(numbers, weights, quantile)
}

func weightedQuantileOf(values, weights []float64, quantile float64) float64 {
	order := make([]int, 0, len(values))
	total := 0.0
	for index := range values {
		if weights[index] > 0 {
			order = append(order, index)
			total += weights[index]
		}
	}
	if len(order) == 0 {
		return 0
	}
	sort.Slice(order, func(i, j int) bool { return values[order[i]] < values[order[j]] })
	threshold := total * quantile
	seen := 0.0
	for _, index := range order {
		seen += weights[index]
		if seen >= threshold {
			return values[index]
		}
	}
	return values[order[len(order)-1]]
}

func weightedVariance(values, weights []float64) float64 {
	sum, total := 0.0, 0.0
	for index, value := range values {
		sum += weights[index] * value
		total += weights[index]
	}
	if total == 0 {
		return 0
	}
	mean := sum / total
	variance := 0.0
	for index, value := range values {
		variance += weights[index] * (value - mean) * (value - mean)
	}
	return variance / total
}

// effectiveCount is Kish's effective sample size for weighted observations.
func effectiveCount(weights []float64) float64 {
	sum, squares := 0.0, 0.0
	for _, weight := range weights {
		sum += weight
		squares += weight * weight
	}
	if squares == 0 {
		return 0
	}
	return sum * sum / squares
}

func lastN(values []int, count int) []int {
	if len(values) <= count {
		return values
	}
	return values[len(values)-count:]
}

func medianInt(values []int) int {
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	return sorted[len(sorted)/2]
}

func clamp(value, minimum, maximum float64) float64 {
	return math.Min(math.Max(value, minimum), maximum)
}

func minutes(value float64) time.Duration { return time.Duration(math.Round(value)) * time.Minute }

func circularMinutes(a, b time.Time) float64 {
	difference := math.Abs(float64((a.Hour()*60 + a.Minute()) - (b.Hour()*60 + b.Minute())))
	return math.Min(difference, 1440-difference)
}
