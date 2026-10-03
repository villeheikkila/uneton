package main

import (
	"math"
	"math/rand/v2"
	"sort"
	"time"
)

// episode is one real-world sleep of a baby, the ground truth that caregivers
// record imperfectly.
type episode struct {
	child      *childModel
	start, end time.Time
	night      bool
	sessionID  string
	// recorder is the device whose action created sessionID.
	recorder *device
}

type childModel struct {
	id        string
	nickname  string
	born      time.Time
	nextWake  time.Time
	sickUntil time.Time
	nextSick  time.Time
	episodes  []*episode
}

func (c *childModel) ageMonths(at time.Time) float64 {
	return at.Sub(c.born).Hours() / 24 / 30.44
}

func (c *childModel) sick(at time.Time) bool { return at.Before(c.sickUntil) }

// episodeAt returns the ground-truth episode containing at, if any.
func (c *childModel) episodeAt(at time.Time) *episode {
	index := sort.Search(len(c.episodes), func(i int) bool { return c.episodes[i].end.After(at) })
	if index < len(c.episodes) && !c.episodes[index].start.After(at) {
		return c.episodes[index]
	}
	return nil
}

func jitter(rng *rand.Rand, value time.Duration, fraction float64) time.Duration {
	return time.Duration(float64(value) * (1 + fraction*(2*rng.Float64()-1)))
}

func between(rng *rand.Rand, low, high time.Duration) time.Duration {
	return low + time.Duration(rng.Int64N(int64(high-low)+1))
}

// wakeWindow follows typical awake spans: under an hour for newborns, five to
// six hours once a toddler drops to one nap around 18 months.
func wakeWindow(months float64) time.Duration {
	steps := []struct {
		until   float64
		minutes float64
	}{{1, 50}, {3, 75}, {5, 105}, {7, 135}, {9, 165}, {12, 195}, {15, 225}, {18, 270}, {math.Inf(1), 330}}
	for _, step := range steps {
		if months < step.until {
			return time.Duration(step.minutes) * time.Minute
		}
	}
	return 330 * time.Minute
}

func napLength(rng *rand.Rand, months float64, sick bool) time.Duration {
	var value time.Duration
	switch {
	case months < 3:
		value = between(rng, 30*time.Minute, 100*time.Minute)
	case months < 12:
		value = between(rng, 40*time.Minute, 110*time.Minute)
	default:
		value = between(rng, 60*time.Minute, 150*time.Minute)
	}
	if sick {
		value = value * 2 / 3
	}
	return value
}

func nightWakings(rng *rand.Rand, months float64, sick bool) int {
	var count int
	switch {
	case months < 3:
		count = 3 + rng.IntN(2)
	case months < 6:
		count = 2 + rng.IntN(2)
	case months < 9:
		count = 1 + rng.IntN(2)
	case months < 15:
		if rng.Float64() < 0.5 {
			count = 1
		}
	default:
		if rng.Float64() < 0.15 {
			count = 1
		}
	}
	if sick {
		count += 1 + rng.IntN(2)
	}
	return count
}

func localClock(day time.Time, hour, minute int, location *time.Location) time.Time {
	return time.Date(day.Year(), day.Month(), day.Day(), hour, minute, 0, 0, location)
}

// planDay generates the naps of one local day and the night that starts that
// evening, continuing from the previous night's wake-up.
func planDay(rng *rand.Rand, child *childModel, day time.Time, location *time.Location) []*episode {
	morning := child.nextWake
	months := child.ageMonths(morning)
	if !morning.Before(child.nextSick) {
		child.sickUntil = morning.Add(between(rng, 4*24*time.Hour, 7*24*time.Hour))
		child.nextSick = child.sickUntil.Add(between(rng, 45*24*time.Hour, 100*24*time.Hour))
	}
	sick := child.sick(morning)
	bedtime := localClock(day, 19, 30, location).Add(jitter(rng, 30*time.Minute, 1))
	if months < 3 {
		bedtime = localClock(day, 21, 0, location).Add(jitter(rng, 45*time.Minute, 1))
	}
	var result []*episode
	window := wakeWindow(months)
	cursor := morning.Add(jitter(rng, window, 0.15))
	for {
		length := napLength(rng, months, sick)
		if cursor.Add(length).Add(window / 2).After(bedtime) {
			break
		}
		result = append(result, &episode{child: child, start: cursor, end: cursor.Add(length)})
		cursor = cursor.Add(length).Add(jitter(rng, window, 0.15))
	}
	if len(result) > 0 && bedtime.Before(result[len(result)-1].end.Add(30*time.Minute)) {
		bedtime = result[len(result)-1].end.Add(30 * time.Minute)
	}
	nextDay := day.AddDate(0, 0, 1)
	wake := localClock(nextDay, 6, 45, location).Add(jitter(rng, 30*time.Minute, 1))
	if months < 3 {
		wake = localClock(nextDay, 7, 0, location).Add(jitter(rng, time.Hour, 1))
	}
	if !wake.After(bedtime.Add(6 * time.Hour)) {
		wake = bedtime.Add(8 * time.Hour)
	}
	wakings := nightWakings(rng, months, sick)
	// Split the night into wakings+1 segments with short awake gaps.
	segment := bedtime
	span := wake.Sub(bedtime)
	for index := 0; index <= wakings; index++ {
		var end time.Time
		if index == wakings {
			end = wake
		} else {
			fraction := float64(index+1) / float64(wakings+1)
			end = bedtime.Add(time.Duration(float64(span) * fraction)).Add(jitter(rng, 20*time.Minute, 1))
		}
		if !end.After(segment.Add(20 * time.Minute)) {
			continue
		}
		result = append(result, &episode{child: child, start: segment, end: end, night: true})
		gap := between(rng, 10*time.Minute, 40*time.Minute)
		if sick {
			gap += between(rng, 10*time.Minute, 30*time.Minute)
		}
		segment = end.Add(gap)
		if !segment.Before(wake.Add(-20 * time.Minute)) {
			break
		}
	}
	child.nextWake = wake
	child.episodes = append(child.episodes, result...)
	return result
}

func weightGrams(months float64) int32 {
	switch {
	case months < 4:
		return int32(3500 + 900*months)
	case months < 12:
		return int32(7100 + 450*(months-4))
	default:
		return int32(10700 + 200*(months-12))
	}
}

func heightMillimeters(months float64) int32 {
	switch {
	case months < 6:
		return int32(500 + 25*months)
	case months < 12:
		return int32(650 + 16*(months-6))
	default:
		return int32(746 + 9*(months-12))
	}
}
