// evaluate-sweetspot performs a chronological, no-future-leakage backtest over
// a user-supplied sleep history. It compares the live model with the frozen
// version 3 and with simple baselines, and prints aggregate errors, never records.
package main

import (
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"sort"
	"strings"
	"time"

	"solutions.bytesized/uneton/platform/backend/cmd/evaluate-sweetspot/v3"
	"solutions.bytesized/uneton/platform/backend/internal/historyimport"
	"solutions.bytesized/uneton/platform/backend/internal/sweetspot"
)

func main() {
	huckleberry := flag.String("csv", "", "Huckleberry sleep-history CSV export")
	plain := flag.String("sessions", "", "CSV of started_at,ended_at RFC 3339 timestamps, one sleep per row")
	timezone := flag.String("timezone", "Europe/Helsinki", "IANA timezone")
	birthDate := flag.String("birth-date", "", "birth date (YYYY-MM-DD)")
	flag.Parse()
	if (*huckleberry == "") == (*plain == "") || *birthDate == "" {
		flag.Usage()
		log.Fatal("exactly one of -csv or -sessions, and -birth-date, are required")
	}
	location, err := time.LoadLocation(*timezone)
	if err != nil {
		log.Fatal(err)
	}
	birth, err := time.ParseInLocation(time.DateOnly, *birthDate, location)
	if err != nil {
		log.Fatal(err)
	}
	sessions, err := load(*huckleberry, *plain, location)
	if err != nil {
		log.Fatal(err)
	}
	if len(sessions) < 2 {
		log.Fatal("need at least two sleeps")
	}
	report := evaluate(sessions, birth, location)
	fmt.Print(report)
}

func load(huckleberry, plain string, location *time.Location) ([]sweetspot.Session, error) {
	path := huckleberry
	if path == "" {
		path = plain
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("close CSV: %v", closeErr)
		}
	}()
	var sessions []sweetspot.Session
	if huckleberry != "" {
		parsed, err := historyimport.Parse(file, location)
		if err != nil {
			return nil, err
		}
		for _, item := range parsed.Sleeps {
			sessions = append(sessions, sweetspot.Session{StartedAt: item.StartedAt, EndedAt: item.EndedAt})
		}
	} else {
		sessions, err = parsePlain(file)
		if err != nil {
			return nil, err
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].StartedAt.Before(sessions[j].StartedAt) })
	return sessions, nil
}

func parsePlain(reader io.Reader) ([]sweetspot.Session, error) {
	rows := csv.NewReader(reader)
	rows.FieldsPerRecord = 2
	var sessions []sweetspot.Session
	for {
		record, err := rows.Read()
		if errors.Is(err, io.EOF) {
			return sessions, nil
		}
		if err != nil {
			return nil, err
		}
		started, startErr := time.Parse(time.RFC3339Nano, strings.TrimSpace(record[0]))
		ended, endErr := time.Parse(time.RFC3339Nano, strings.TrimSpace(record[1]))
		if startErr != nil || endErr != nil {
			continue // header or malformed row
		}
		sessions = append(sessions, sweetspot.Session{StartedAt: started, EndedAt: ended})
	}
}

// prediction is a point estimate with an interval and the coverage it claims.
type prediction struct {
	target, low, high time.Time
	coverage          float64 // nominal probability that the outcome falls in [low, high]; 0 when no interval
}

type predictor struct {
	name    string
	predict func(wokeAt time.Time, history []sweetspot.Session, current *sweetspot.Session) (prediction, bool)
}

func predictors(birth time.Time, location *time.Location) []predictor {
	return []predictor{
		{"age-prior", func(wokeAt time.Time, _ []sweetspot.Session, current *sweetspot.Session) (prediction, bool) {
			estimate, ok := v3.Predict(v3.Request{WokeAt: wokeAt, BirthDate: birth, Location: location})
			return prediction{estimate.Target, estimate.RangeStart, estimate.RangeEnd, 0.5}, ok
		}},
		{"last-window", func(wokeAt time.Time, history []sweetspot.Session, _ *sweetspot.Session) (prediction, bool) {
			for _, window := range reversedWindows(history) {
				if clockDistance(window.wokeAt.In(location), wokeAt.In(location)) <= 180 {
					target := wokeAt.Add(window.length)
					return prediction{target, target, target, 0}, true
				}
			}
			return prediction{}, false
		}},
		{"personal-median", func(wokeAt time.Time, history []sweetspot.Session, _ *sweetspot.Session) (prediction, bool) {
			var lengths []float64
			for _, window := range reversedWindows(history) {
				if wokeAt.Sub(window.wokeAt) > 14*24*time.Hour {
					break
				}
				if clockDistance(window.wokeAt.In(location), wokeAt.In(location)) <= 90 {
					lengths = append(lengths, window.length.Minutes())
				}
			}
			if len(lengths) < 3 {
				return prediction{}, false
			}
			sort.Float64s(lengths)
			at := func(q float64) time.Time { return wokeAt.Add(minutes(lengths[int(q*float64(len(lengths)-1))])) }
			return prediction{at(0.5), at(0.25), at(0.75), 0.5}, true
		}},
		{"v3", func(wokeAt time.Time, history []sweetspot.Session, current *sweetspot.Session) (prediction, bool) {
			converted := make([]v3.Session, len(history))
			for index, item := range history {
				converted[index] = v3.Session{StartedAt: item.StartedAt, EndedAt: item.EndedAt}
			}
			var previous *v3.Session
			if current != nil {
				previous = &v3.Session{StartedAt: current.StartedAt, EndedAt: current.EndedAt}
			}
			estimate, ok := v3.Predict(v3.Request{WokeAt: wokeAt, BirthDate: birth, Location: location, History: converted, Current: previous})
			return prediction{estimate.Target, estimate.RangeStart, estimate.RangeEnd, 0.5}, ok
		}},
		{fmt.Sprintf("live v%d", sweetspot.AlgorithmVersion), func(wokeAt time.Time, history []sweetspot.Session, current *sweetspot.Session) (prediction, bool) {
			estimate, ok := sweetspot.Predict(sweetspot.Request{WokeAt: wokeAt, BirthDate: birth, Location: location, History: history, Current: current})
			return prediction{estimate.Target, estimate.RangeStart, estimate.RangeEnd, estimate.Coverage}, ok
		}},
	}
}

type window struct {
	wokeAt time.Time
	length time.Duration
}

// reversedWindows lists wake windows (end of one sleep to start of the next),
// newest first, skipping gaps that cannot be a single wake period.
func reversedWindows(history []sweetspot.Session) []window {
	var result []window
	for index := len(history) - 1; index > 0; index-- {
		gap := history[index].StartedAt.Sub(history[index-1].EndedAt)
		if gap >= 5*time.Minute && gap <= 8*time.Hour {
			result = append(result, window{wokeAt: history[index-1].EndedAt, length: gap})
		}
	}
	return result
}

type metrics struct {
	errors, pinball, widths []float64
	within15, within30      int
	covered, withInterval   int
	nominalTotal            float64
}

func (m *metrics) add(p prediction, actual time.Time) {
	errorMinutes := actual.Sub(p.target).Minutes()
	m.errors = append(m.errors, math.Abs(errorMinutes))
	if math.Abs(errorMinutes) <= 15 {
		m.within15++
	}
	if math.Abs(errorMinutes) <= 30 {
		m.within30++
	}
	loss := quantileLoss(actual, p.target, 0.5)
	if p.coverage > 0 {
		m.withInterval++
		m.nominalTotal += p.coverage
		m.widths = append(m.widths, p.high.Sub(p.low).Minutes())
		if !actual.Before(p.low) && !actual.After(p.high) {
			m.covered++
		}
		tail := (1 - p.coverage) / 2
		loss = (quantileLoss(actual, p.low, tail) + loss + quantileLoss(actual, p.high, 1-tail)) / 3
	}
	m.pinball = append(m.pinball, loss)
}

// quantileLoss is the pinball loss in minutes for a predicted quantile.
func quantileLoss(actual, predicted time.Time, quantile float64) float64 {
	difference := actual.Sub(predicted).Minutes()
	if difference >= 0 {
		return quantile * difference
	}
	return (quantile - 1) * difference
}

func (m *metrics) line(name string) string {
	if len(m.errors) == 0 {
		return ""
	}
	count := len(m.errors)
	sorted := append([]float64(nil), m.errors...)
	sort.Float64s(sorted)
	coverage := "    -"
	width := "   -"
	if m.withInterval > 0 {
		coverage = fmt.Sprintf("%3.0f/%2.0f", percentage(m.covered, m.withInterval), 100*m.nominalTotal/float64(m.withInterval))
		width = fmt.Sprintf("%4.0f", mean(m.widths))
	}
	return fmt.Sprintf("  %-16s n=%4d MAE=%5.1f median=%4.0f within15=%3.0f%% within30=%3.0f%% pinball=%5.1f coverage(actual/nominal)=%s%% width=%sm\n",
		name, count, mean(m.errors), sorted[count/2], percentage(m.within15, count), percentage(m.within30, count), mean(m.pinball), coverage, width)
}

func evaluate(sessions []sweetspot.Session, birth time.Time, location *time.Location) string {
	all := predictors(birth, location)
	type key struct{ group, model string }
	results := map[key]*metrics{}
	groups := []string{}
	seen := map[string]bool{}
	record := func(group, model string, p prediction, actual time.Time) {
		if !seen[group] {
			seen[group] = true
			groups = append(groups, group)
		}
		k := key{group, model}
		if results[k] == nil {
			results[k] = &metrics{}
		}
		results[k].add(p, actual)
	}
	for index := 1; index < len(sessions); index++ {
		actual := sessions[index].StartedAt
		wokeAt := sessions[index-1].EndedAt
		gap := actual.Sub(wokeAt)
		if gap < 5*time.Minute || gap > 8*time.Hour {
			continue
		}
		history := sessions[:index]
		current := sessions[index-1]
		predictions := make([]prediction, len(all))
		complete := true
		for model, candidate := range all {
			p, ok := candidate.predict(wokeAt, history, &current)
			if !ok {
				complete = false
				break
			}
			predictions[model] = p
		}
		// Compare models only on events every model could predict.
		if !complete {
			continue
		}
		local := wokeAt.In(location)
		for model, candidate := range all {
			record("all", candidate.name, predictions[model], actual)
			record("phase "+reportPhase(local), candidate.name, predictions[model], actual)
			record("age "+ageBand(birth, wokeAt), candidate.name, predictions[model], actual)
		}
	}
	// Wake prediction for an ongoing sleep, asked 20 minutes after it started.
	// Night sleeps are judged against the morning wake (end of the night's last
	// segment), naps against their own end.
	wake := map[string]map[string]*metrics{"night": {}, "nap": {}}
	for index := 1; index < len(sessions); index++ {
		active := sessions[index]
		asked := active.StartedAt.Add(20 * time.Minute)
		if !active.EndedAt.After(asked) {
			continue
		}
		history := sessions[:index]
		live, liveOK := sweetspot.PredictWake(sweetspot.Session{StartedAt: active.StartedAt}, asked, location, history)
		converted := make([]v3.Session, len(history))
		for position, item := range history {
			converted[position] = v3.Session{StartedAt: item.StartedAt, EndedAt: item.EndedAt}
		}
		old, oldOK := v3.PredictWake(v3.Session{StartedAt: active.StartedAt}, asked, location, converted)
		if !liveOK || !oldOK {
			continue
		}
		kind, actual := "nap", active.EndedAt
		if live.Kind == "morning-wake" {
			kind, actual = "night", morningAfter(sessions, index, location)
			if actual.IsZero() {
				continue
			}
		}
		for name, p := range map[string]prediction{"v3": {old.Target, old.RangeStart, old.RangeEnd, 0.5}, fmt.Sprintf("live v%d", sweetspot.AlgorithmVersion): {live.Target, live.RangeStart, live.RangeEnd, live.Coverage}} {
			if wake[kind][name] == nil {
				wake[kind][name] = &metrics{}
			}
			wake[kind][name].add(p, actual)
		}
	}
	var output strings.Builder
	first, last := sessions[0].StartedAt.In(location), sessions[len(sessions)-1].EndedAt.In(location)
	fmt.Fprintf(&output, "history: %d sleeps from %s to %s (age %s to %s)\n", len(sessions), first.Format(time.DateOnly), last.Format(time.DateOnly), ageBand(birth, first), ageBand(birth, last))
	fmt.Fprintln(&output, "next sleep onset, errors in minutes; pinball averages the target and interval quantiles")
	sort.SliceStable(groups, func(i, j int) bool { return groupOrder(groups[i]) < groupOrder(groups[j]) })
	for _, group := range groups {
		fmt.Fprintf(&output, "%s\n", group)
		for _, candidate := range all {
			if m := results[key{group, candidate.name}]; m != nil {
				output.WriteString(m.line(candidate.name))
			}
		}
	}
	for _, kind := range []string{"night", "nap"} {
		fmt.Fprintf(&output, "wake prediction, %s (target: %s)\n", kind, map[string]string{"night": "morning wake", "nap": "nap end"}[kind])
		for _, name := range []string{"v3", fmt.Sprintf("live v%d", sweetspot.AlgorithmVersion)} {
			if m := wake[kind][name]; m != nil {
				output.WriteString(m.line(name))
			}
		}
	}
	return output.String()
}

// morningAfter follows a night from sessions[index] through wakings of at most
// three hours, resumed before six in the morning, and returns the end of its
// last segment. It mirrors the diary's plain meaning, not the model's rules.
func morningAfter(sessions []sweetspot.Session, index int, location *time.Location) time.Time {
	end := sessions[index].EndedAt
	for next := index + 1; next < len(sessions); next++ {
		start := sessions[next].StartedAt
		hour := start.In(location).Hour()
		if start.Sub(end) > 3*time.Hour || (hour >= 6 && hour < 18) {
			break
		}
		end = sessions[next].EndedAt
	}
	if hour := end.In(location).Hour(); hour < 4 || hour >= 12 {
		return time.Time{} // the night has no recorded morning
	}
	return end
}

func groupOrder(group string) string {
	switch {
	case group == "all":
		return "0"
	case strings.HasPrefix(group, "phase"):
		return "1" + group
	default:
		return "2" + group
	}
}

// reportPhase groups events by clock time for reporting only, independent of
// any model's own notion of day structure.
func reportPhase(local time.Time) string {
	hour := local.Hour()
	switch {
	case hour >= 20 || hour < 6:
		return "night"
	case hour < 11:
		return "morning"
	case hour < 17:
		return "afternoon"
	default:
		return "evening"
	}
}

func ageBand(birth, at time.Time) string {
	months := at.Sub(birth).Hours() / 24 / 30.4375
	switch {
	case months < 3:
		return "0-3m"
	case months < 6:
		return "3-6m"
	case months < 12:
		return "6-12m"
	case months < 24:
		return "12-24m"
	default:
		return "24m+"
	}
}

func clockDistance(a, b time.Time) float64 {
	difference := math.Abs(float64((a.Hour()*60 + a.Minute()) - (b.Hour()*60 + b.Minute())))
	return math.Min(difference, 1440-difference)
}

func mean(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sum := 0.0
	for _, value := range values {
		sum += value
	}
	return sum / float64(len(values))
}

func percentage(value, total int) float64 { return 100 * float64(value) / float64(total) }

func minutes(value float64) time.Duration { return time.Duration(math.Round(value)) * time.Minute }
