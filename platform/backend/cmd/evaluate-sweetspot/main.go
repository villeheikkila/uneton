// evaluate-sweetspot performs a chronological, no-future-leakage backtest over
// a user-supplied sleep-history CSV. It prints aggregate errors, never records.
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"sort"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/historyimport"
	"solutions.bytesized/uneton/platform/backend/internal/sweetspot"
)

type metrics struct {
	count, within15, within30, covered int
	errors                             []float64
}

func main() {
	csvPath := flag.String("csv", "", "sleep-history CSV export")
	timezone := flag.String("timezone", "Europe/Helsinki", "IANA timezone")
	birthDate := flag.String("birth-date", "", "birth date (YYYY-MM-DD)")
	flag.Parse()
	if *csvPath == "" || *birthDate == "" {
		flag.Usage()
		log.Fatal("csv and birth-date are required")
	}
	location, err := time.LoadLocation(*timezone)
	if err != nil {
		log.Fatal(err)
	}
	birth, err := time.ParseInLocation(time.DateOnly, *birthDate, location)
	if err != nil {
		log.Fatal(err)
	}
	file, err := os.Open(*csvPath)
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			log.Printf("close CSV: %v", closeErr)
		}
	}()
	parsed, err := historyimport.Parse(file, location)
	if err != nil {
		log.Fatal(err)
	}
	sessions := make([]sweetspot.Session, 0, len(parsed.Sleeps))
	for _, item := range parsed.Sleeps {
		sessions = append(sessions, sweetspot.Session{StartedAt: item.StartedAt, EndedAt: item.EndedAt})
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].StartedAt.Before(sessions[j].StartedAt) })
	byKind := map[string]*metrics{}
	all := &metrics{}
	for index := 1; index < len(sessions); index++ {
		actual := sessions[index].StartedAt
		wokeAt := sessions[index-1].EndedAt
		gap := actual.Sub(wokeAt)
		if gap < 5*time.Minute || gap > 8*time.Hour {
			continue
		}
		estimate, ok := sweetspot.Predict(sweetspot.Request{WokeAt: wokeAt, BirthDate: birth, Location: location, History: sessions[:index], Current: &sessions[index-1]})
		if !ok {
			continue
		}
		add(all, estimate, actual)
		if byKind[estimate.Kind] == nil {
			byKind[estimate.Kind] = &metrics{}
		}
		add(byKind[estimate.Kind], estimate, actual)
	}
	printMetrics("sweetspot", all)
	for _, kind := range []string{"resettle", "morning", "daytime", "bedtime"} {
		printMetrics(kind, byKind[kind])
	}
	last := sessions[len(sessions)-1]
	estimate, ok := sweetspot.Predict(sweetspot.Request{WokeAt: last.EndedAt, BirthDate: birth, Location: location, History: sessions, Current: &last})
	if ok {
		fmt.Printf("latest: kind=%s target=%s range=%s..%s confidence=%s samples=%d\n", estimate.Kind, estimate.Target.In(location).Format("2006-01-02 15:04"), estimate.RangeStart.In(location).Format("15:04"), estimate.RangeEnd.In(location).Format("15:04"), estimate.Confidence, estimate.SampleCount)
	}
}

func add(value *metrics, estimate sweetspot.Estimate, actual time.Time) {
	errorMinutes := math.Abs(actual.Sub(estimate.Target).Minutes())
	value.count++
	value.errors = append(value.errors, errorMinutes)
	if errorMinutes <= 15 {
		value.within15++
	}
	if errorMinutes <= 30 {
		value.within30++
	}
	if !actual.Before(estimate.RangeStart) && !actual.After(estimate.RangeEnd) {
		value.covered++
	}
}

func printMetrics(name string, value *metrics) {
	if value == nil || value.count == 0 {
		return
	}
	sort.Float64s(value.errors)
	sum := 0.0
	for _, item := range value.errors {
		sum += item
	}
	fmt.Printf("%-9s n=%3d MAE=%5.1fm median=%4.0fm within15=%4.0f%% within30=%4.0f%% rangeCoverage=%4.0f%%\n", name, value.count, sum/float64(value.count), value.errors[len(value.errors)/2], percentage(value.within15, value.count), percentage(value.within30, value.count), percentage(value.covered, value.count))
}

func percentage(value, total int) float64 { return 100 * float64(value) / float64(total) }
