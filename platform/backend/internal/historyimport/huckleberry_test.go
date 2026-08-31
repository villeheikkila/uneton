package historyimport

import (
	"context"
	"strings"
	"testing"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store"
)

func TestImportIsAtomicAndIdempotent(t *testing.T) {
	database, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	const (
		familyID = "10000000-0000-4000-8000-000000000001"
		childID  = "20000000-0000-4000-8000-000000000001"
		ownerID  = "30000000-0000-4000-8000-000000000001"
	)
	now := time.Date(2026, 1, 2, 12, 0, 0, 0, time.UTC)
	seedImportTarget(t, database, familyID, childID, ownerID, now)
	parsed, err := Parse(strings.NewReader("Type,Start,End,Start Location\nSleep,2026-01-01 08:00,2026-01-01 09:00,On own in bed\nSleep,2026-01-01 08:01,2026-01-01 09:05,\nSleep,2026-01-01 12:00,2026-01-01 13:00,Swing\n"), time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	options := ImportOptions{FamilyID: familyID, ChildID: childID, AuthorID: ownerID, Now: func() time.Time { return now }}
	first, err := Import(context.Background(), database, parsed, options)
	if err != nil {
		t.Fatal(err)
	}
	if first.Inserted != 2 || first.Parsed != 3 || first.Merged != 1 {
		t.Fatalf("first import = %+v", first)
	}
	assertCount(t, database, "sleep_sessions", 2)
	assertCount(t, database, "sync_events", 2)
	var syncedLocations int
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM sync_events WHERE entity_type='sleepSession' AND json_extract(payload_json, '$.sleepLocation') <> ''").Scan(&syncedLocations); err != nil {
		t.Fatal(err)
	}
	if syncedLocations != 2 {
		t.Fatalf("synced structured sleep locations = %d, want 2", syncedLocations)
	}

	second, err := Import(context.Background(), database, parsed, options)
	if err != nil {
		t.Fatal(err)
	}
	if second.Inserted != 0 {
		t.Fatalf("second import inserted %d sleeps", second.Inserted)
	}
	assertCount(t, database, "sleep_sessions", 2)
	assertCount(t, database, "sync_events", 2)
}

func TestParseIgnoresNonSleepRows(t *testing.T) {
	input := "Type,Start,End\nFeed,2026-01-01 09:00,2026-01-01 09:05\nSleep,2026-01-01 10:00,2026-01-01 10:30\n"
	parsed, err := Parse(strings.NewReader(input), time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Sleeps) != 1 || parsed.Ignored != 1 {
		t.Fatalf("parsed = %+v", parsed)
	}
}

func assertCount(t *testing.T, database *store.Store, table string, expected int) {
	t.Helper()
	var actual int
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&actual); err != nil {
		t.Fatal(err)
	}
	if actual != expected {
		t.Fatalf("%s count = %d, want %d", table, actual, expected)
	}
}

func seedImportTarget(t *testing.T, database *store.Store, familyID, childID, ownerID string, now time.Time) {
	t.Helper()
	timestamp := now.Format(time.RFC3339Nano)
	for _, statement := range []struct {
		query string
		args  []any
	}{
		{"INSERT INTO users(id, apple_subject, display_name, created_at) VALUES (?, ?, ?, ?)", []any{ownerID, "test:owner", "Owner", timestamp}},
		{"INSERT INTO families(id, name, owner_id, created_at) VALUES (?, ?, ?, ?)", []any{familyID, "Test family", ownerID, timestamp}},
		{"INSERT INTO family_members(family_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)", []any{familyID, ownerID, "owner", timestamp}},
		{"INSERT INTO children(id, family_id, nickname, birth_date, time_zone, updated_at) VALUES (?, ?, ?, ?, ?, ?)", []any{childID, familyID, "Child", "2025-01-01", "UTC", timestamp}},
	} {
		if _, err := database.DB.Exec(statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}
}
