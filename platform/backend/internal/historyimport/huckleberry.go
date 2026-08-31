package historyimport

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

type Sleep struct {
	StartedAt      time.Time
	EndedAt        time.Time
	StartCondition string
	SleepLocation  string
	EndCondition   string
}

type Parsed struct {
	Sleeps  []Sleep
	Ignored int
}

type ImportOptions struct {
	FamilyID string
	ChildID  string
	AuthorID string
	Now      func() time.Time
}

type ImportResult struct {
	Parsed   int
	Inserted int
	Merged   int
	Ignored  int
}

func Parse(reader io.Reader, location *time.Location) (Parsed, error) {
	if location == nil {
		return Parsed{}, errors.New("timezone is required")
	}
	r := csv.NewReader(reader)
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return Parsed{}, fmt.Errorf("read header: %w", err)
	}
	columns := make(map[string]int, len(header))
	for index, value := range header {
		columns[strings.ToLower(strings.TrimSpace(strings.TrimPrefix(value, "\ufeff")))] = index
	}
	for _, required := range []string{"type", "start", "end"} {
		if _, ok := columns[required]; !ok {
			return Parsed{}, fmt.Errorf("missing required %q column", required)
		}
	}
	var result Parsed
	for line := 2; ; line++ {
		record, readErr := r.Read()
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return Parsed{}, fmt.Errorf("row %d: %w", line, readErr)
		}
		value := func(name string) string {
			index := columns[name]
			if index >= len(record) {
				return ""
			}
			return strings.TrimSpace(record[index])
		}
		if !strings.EqualFold(value("type"), "Sleep") {
			result.Ignored++
			continue
		}
		start, err := parseTimestamp(value("start"), location)
		if err != nil {
			return Parsed{}, fmt.Errorf("row %d start: %w", line, err)
		}
		end, err := parseTimestamp(value("end"), location)
		if err != nil {
			return Parsed{}, fmt.Errorf("row %d end: %w", line, err)
		}
		if !end.After(start) {
			return Parsed{}, fmt.Errorf("row %d: sleep end must be after start", line)
		}
		result.Sleeps = append(result.Sleeps, Sleep{
			StartedAt: start.UTC(), EndedAt: end.UTC(),
			StartCondition: value("start condition"),
			SleepLocation:  normalizeLocation(value("start location")),
			EndCondition:   value("end condition"),
		})
	}
	sort.SliceStable(result.Sleeps, func(i, j int) bool {
		if result.Sleeps[i].StartedAt.Equal(result.Sleeps[j].StartedAt) {
			return result.Sleeps[i].EndedAt.Before(result.Sleeps[j].EndedAt)
		}
		return result.Sleeps[i].StartedAt.Before(result.Sleeps[j].StartedAt)
	})
	return result, nil
}

func parseTimestamp(value string, location *time.Location) (time.Time, error) {
	if value == "" {
		return time.Time{}, errors.New("timestamp is empty")
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed, nil
		}
	}
	for _, layout := range []string{
		"2006-01-02 15:04:05", "2006-01-02 15:04",
		"01/02/2006 03:04 PM", "1/2/2006 3:04 PM",
	} {
		if parsed, err := time.ParseInLocation(layout, value, location); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported timestamp %q", value)
}

func Import(ctx context.Context, database *store.Store, parsed Parsed, options ImportOptions) (ImportResult, error) {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.FamilyID == "" || options.ChildID == "" || options.AuthorID == "" {
		return ImportResult{}, errors.New("family, child, and author identifiers are required")
	}

	tx, err := database.DB.BeginTx(ctx, nil)
	if err != nil {
		return ImportResult{}, err
	}
	defer func() { _ = tx.Rollback() }()
	q := database.Queries.WithTx(tx)
	nowTime := options.Now().UTC()
	now := nowTime.Format(time.RFC3339Nano)
	if _, err := q.ImportTarget(ctx, storedb.ImportTargetParams{AuthorID: options.AuthorID, ChildID: options.ChildID, FamilyID: options.FamilyID}); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ImportResult{}, errors.New("import target must be an active child and caregiver in the family")
		}
		return ImportResult{}, err
	}

	normalized := normalize(parsed.Sleeps)
	result := ImportResult{Parsed: len(parsed.Sleeps), Merged: len(parsed.Sleeps) - len(normalized), Ignored: parsed.Ignored}
	duplicates := make(map[string]int)
	for _, sleep := range normalized {
		identity := sleep.StartedAt.Format(time.RFC3339Nano) + "|" + sleep.EndedAt.Format(time.RFC3339Nano)
		ordinal := duplicates[identity]
		duplicates[identity]++
		id := deterministicID(options.FamilyID + "|" + options.ChildID + "|" + identity + fmt.Sprintf("|%d", ordinal))
		rows, err := q.ImportSleep(ctx, storedb.ImportSleepParams{
			ID: id, FamilyID: options.FamilyID, ChildID: options.ChildID,
			StartedAt: sleep.StartedAt.Format(time.RFC3339Nano), EndedAt: sql.NullString{String: sleep.EndedAt.Format(time.RFC3339Nano), Valid: true},
			AuthorID: options.AuthorID, UpdatedAt: now,
		})
		if err != nil {
			return ImportResult{}, fmt.Errorf("import sleep %s: %w", id, err)
		}
		if err := q.ImportSleepContext(ctx, storedb.ImportSleepContextParams{ID: id, StartCondition: sleep.StartCondition, SleepLocation: sleep.SleepLocation, EndCondition: sleep.EndCondition}); err != nil {
			return ImportResult{}, fmt.Errorf("import sleep context %s: %w", id, err)
		}
		if rows == 0 {
			continue
		}
		payload, err := json.Marshal(map[string]any{
			"id": id, "familyID": options.FamilyID, "childID": options.ChildID,
			"startedAt": sleep.StartedAt, "endedAt": sleep.EndedAt, "revision": 1,
			"authorID": options.AuthorID, "source": "history_import",
			"startCondition": sleep.StartCondition, "sleepLocation": sleep.SleepLocation,
			"endCondition": sleep.EndCondition, "wakeMood": "unknown", "wakeReason": "unknown",
			"updatedAt": nowTime,
		})
		if err != nil {
			return ImportResult{}, err
		}
		if err := q.AppendEvent(ctx, storedb.AppendEventParams{
			FamilyID: options.FamilyID, EntityType: "sleepSession", EntityID: id,
			Operation: "upsert", Revision: 1, PayloadJson: payload, CreatedAt: now,
		}); err != nil {
			return ImportResult{}, err
		}
		result.Inserted++
	}
	if err := tx.Commit(); err != nil {
		return ImportResult{}, err
	}
	return result, nil
}

func normalize(sleeps []Sleep) []Sleep {
	values := append([]Sleep(nil), sleeps...)
	sort.SliceStable(values, func(i, j int) bool {
		if values[i].StartedAt.Equal(values[j].StartedAt) {
			return values[i].EndedAt.Before(values[j].EndedAt)
		}
		return values[i].StartedAt.Before(values[j].StartedAt)
	})
	result := make([]Sleep, 0, len(values))
	for _, sleep := range values {
		if len(result) == 0 {
			result = append(result, sleep)
			continue
		}
		previous := &result[len(result)-1]
		near := sleep.StartedAt.Sub(previous.StartedAt) <= 2*time.Minute
		overlaps := !sleep.StartedAt.After(previous.EndedAt)
		if !near && !overlaps {
			result = append(result, sleep)
			continue
		}
		if sleep.StartedAt.Before(previous.StartedAt) {
			previous.StartedAt = sleep.StartedAt
		}
		if sleep.EndedAt.After(previous.EndedAt) {
			previous.EndedAt = sleep.EndedAt
			previous.EndCondition = sleep.EndCondition
		}
		if previous.StartCondition == "" {
			previous.StartCondition = sleep.StartCondition
		}
		if previous.SleepLocation == "" {
			previous.SleepLocation = sleep.SleepLocation
		}
	}
	return result
}

func normalizeLocation(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "on own in bed":
		return "crib"
	case "co sleep":
		return "cosleep"
	case "swing":
		return "motion"
	case "nursing":
		return "feeding"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func deterministicID(value string) string {
	sum := sha256.Sum256([]byte(value))
	bytes := sum[:16]
	bytes[6] = (bytes[6] & 0x0f) | 0x50
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(bytes)
	return fmt.Sprintf("%s-%s-%s-%s-%s", encoded[:8], encoded[8:12], encoded[12:16], encoded[16:20], encoded[20:])
}
