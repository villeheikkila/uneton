package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
)

// TestSeededQuarterYear runs 90 simulated days of one family with faults and
// requires every daily invariant to hold.
func TestSeededQuarterYear(t *testing.T) {
	if testing.Short() {
		t.Skip("simulation skipped in short mode")
	}
	cfg := defaultConfig()
	cfg.days, cfg.freshEvery = 90, 30
	var output bytes.Buffer
	cfg.out = &output
	if err := simulate(cfg); err != nil {
		t.Fatalf("simulation failed:\n%s", output.String())
	}
}

func scenario(t *testing.T, mutate func(*config)) *simulation {
	t.Helper()
	cfg := defaultConfig()
	cfg.faultRate, cfg.keepGoing, cfg.freshEvery = 0, true, 0
	var output bytes.Buffer
	cfg.out = &output
	if mutate != nil {
		mutate(&cfg)
	}
	s, err := newSimulation(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.close)
	if err := s.setup(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if t.Failed() {
			t.Log(output.String())
			t.Log("event log:\n  " + strings.Join(s.log, "\n  "))
		}
	})
	return s
}

// logNaps records one nap per simulated hour from the owner's phone.
func logNaps(s *simulation, count int) {
	for range count {
		_ = s.clock.Set(s.clock.Now().Add(time.Hour))
		start := s.clock.Now().Add(-50 * time.Minute)
		s.act(s.owner, false, func() { s.owner.upsertSleep(s.children[0].id, s.newID(), start, start.Add(40*time.Minute)) })
	}
}

// A restore inside the restore horizon loses no acknowledged command even
// though every device has pruned its journal by the server's cutoff.
func TestRestoreWithinHorizonLosesNoAcknowledgedIntentAfterPruning(t *testing.T) {
	s := scenario(t, nil)
	for range 10 {
		logNaps(s, 24)
	}
	before := len(s.owner.journal)
	if s.stats.journalPruned == 0 || before >= len(s.acknowledged) {
		t.Fatalf("journal was not pruned: %d entries for %d acknowledged commands", before, len(s.acknowledged))
	}
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	logNaps(s, 20)
	s.restore(backup.id)
	devices := s.quiesce(false)
	s.verify(devices)
	if len(s.failures) > 0 {
		t.Fatalf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
	if s.stats.journalReplays == 0 {
		t.Fatal("restore did not replay the journal")
	}
}

// Negative control: a restore older than the journal retention loses
// acknowledged commands, and the invariant reports it.
func TestRestoreBeyondJournalRetentionIsDetected(t *testing.T) {
	s := scenario(t, func(cfg *config) { cfg.journalRetention = time.Hour })
	logNaps(s, 2)
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	logNaps(s, 6)
	s.restore(backup.id)
	s.verify(s.quiesce(false))
	if !strings.Contains(strings.Join(s.failures, "\n"), "acknowledged intent") {
		t.Fatalf("expected lost acknowledged commands to be reported, got %v", s.failures)
	}
}

func TestServeControlEndpoints(t *testing.T) {
	start := time.Date(2026, time.March, 1, 8, 0, 0, 0, time.UTC)
	clock := newSimClock(start)
	b, err := openBackend(backendOptions{path: filepath.Join(t.TempDir(), "serve.sqlite"), clock: clock, compactionThreshold: 100})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	server := httptest.NewServer(controlMux(b, clock))
	defer server.Close()
	post := func(path string, body any) (int, map[string]string) {
		encoded, _ := json.Marshal(body)
		response, err := http.Post(server.URL+path, "application/json", bytes.NewReader(encoded))
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = response.Body.Close() }()
		var decoded map[string]string
		_ = json.NewDecoder(response.Body).Decode(&decoded)
		return response.StatusCode, decoded
	}
	if status, body := post("/_sim/clock", map[string]float64{"advanceSeconds": 3600}); status != http.StatusOK || body["now"] != start.Add(time.Hour).Format(time.RFC3339Nano) {
		t.Fatalf("advance: %d %v", status, body)
	}
	if status, _ := post("/_sim/clock", map[string]string{"now": start.Format(time.RFC3339Nano)}); status != http.StatusBadRequest {
		t.Fatalf("clock moved backwards: %d", status)
	}
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	auth, err := client.DevelopmentAuth(context.Background(), connect.NewRequest(&unetonv1.DevelopmentAuthRequest{Name: "Parent", DeviceId: "8a3d4c1e-0b8f-4a57-9b5e-2f0c7d1e9a11"}))
	if err != nil {
		t.Fatal(err)
	}
	status, checkpoint := post("/_sim/checkpoint", nil)
	if status != http.StatusOK || checkpoint["id"] == "" {
		t.Fatalf("checkpoint: %d %v", status, checkpoint)
	}
	generation := b.Generation()
	if status, _ := post("/_sim/restart", nil); status != http.StatusOK || b.Generation() != generation {
		t.Fatalf("restart changed generation or failed: %d", status)
	}
	if _, err := client.DevelopmentAuth(context.Background(), connect.NewRequest(&unetonv1.DevelopmentAuthRequest{Name: "Parent", DeviceId: "8a3d4c1e-0b8f-4a57-9b5e-2f0c7d1e9a11"})); err != nil {
		t.Fatalf("API unavailable after restart: %v", err)
	}
	if status, body := post("/_sim/restore", map[string]string{"id": checkpoint["id"]}); status != http.StatusOK || body["generation"] == generation {
		t.Fatalf("restore did not rotate the generation: %d %v", status, body)
	}
	request := connect.NewRequest(&unetonv1.CreateFamilyRequest{Name: "Home"})
	request.Header().Set("Authorization", "Bearer "+auth.Msg.GetAuthentication().GetAccessToken())
	if _, err := client.CreateFamily(context.Background(), request); err != nil {
		t.Fatalf("token issued before the checkpoint stopped working after restore: %v", err)
	}
}

func covered(truth map[string]*view, childID string, start, end time.Time) bool {
	for _, v := range truth {
		if v.Type == "sleepSession" && v.ChildID == childID && v.End != nil && v.Start.Before(end) && v.End.After(start) {
			return true
		}
	}
	return false
}

// Reproduction: Parent B starts a timer while offline. Parent A cannot see it
// and logs the same sleep from memory. When B reconnects, its start creates a
// second session over the logged one, and nothing merges them.
func TestOfflineStartOverAManuallyLoggedSleepLeavesNoOverlap(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(10 * time.Hour))
	start := s.clock.Now()
	s.partner.online = false
	s.act(s.partner, false, func() { s.partner.startSleep(child, s.newID(), start, "phone") })
	_ = s.clock.Set(start.Add(time.Hour))
	s.act(s.owner, true, func() { s.owner.upsertSleep(child, s.newID(), start, start.Add(time.Hour)) })
	_ = s.clock.Set(start.Add(3 * time.Hour))
	s.partner.online = true
	s.sync(s.partner)
	if active := s.partner.activeSleep(child); active != nil {
		s.act(s.partner, false, func() { s.partner.endSleep(active.ID, start.Add(time.Hour), "unknown", "unknown") })
	}
	s.verify(s.quiesce(false))
	if len(s.failures) > 0 {
		t.Fatalf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
}

// Reproduction: snapshots omit deleted entities, so after a reset the stored
// result of a replayed create lands in an empty cache and resurrects an entity
// that was deleted before the backup. Found by seeds 2 and 3.
func TestRestoreReplayDoesNotResurrectDeletedEntities(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	reading := s.newID()
	_ = s.clock.Set(s.clock.Now().Add(10 * time.Hour))
	s.act(s.owner, true, func() { s.owner.upsertTemperature(child, reading, s.clock.Now(), 3810, "") })
	_ = s.clock.Set(s.clock.Now().Add(time.Hour))
	s.sync(s.partner)
	s.act(s.partner, true, func() { s.partner.deleteTemperature(reading) })
	_ = s.clock.Set(s.clock.Now().Add(time.Hour))
	s.sync(s.owner)
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	_ = s.clock.Set(s.clock.Now().Add(2 * time.Hour))
	s.restore(backup.id)
	s.verify(s.quiesce(false))
	if len(s.failures) > 0 {
		t.Fatalf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
}

// Reproduction: after a restore, Parent A's journal replays a nap's start
// while Parent B's night sleep is active again in the restored database. The
// server maps the nap's start onto the night sleep, the client redirects the
// nap's end to it, and the nap disappears.
func TestRestoreReplayDoesNotFoldANapIntoAnotherCaregiversNight(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(18 * time.Hour))
	nightStart := s.clock.Now()
	night := s.newID()
	s.act(s.partner, true, func() { s.partner.startSleep(child, night, nightStart, "phone") })
	_ = s.clock.Set(nightStart.Add(2 * time.Hour))
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	_ = s.clock.Set(nightStart.Add(11 * time.Hour))
	s.act(s.partner, true, func() { s.partner.endSleep(night, s.clock.Now(), "calm", "natural") })
	_ = s.clock.Set(nightStart.Add(15 * time.Hour))
	napStart := s.clock.Now()
	nap := s.newID()
	s.act(s.owner, true, func() { s.owner.startSleep(child, nap, napStart, "phone") })
	_ = s.clock.Set(napStart.Add(time.Hour))
	s.act(s.owner, true, func() { s.owner.endSleep(nap, s.clock.Now(), "calm", "natural") })
	_ = s.clock.Set(napStart.Add(2 * time.Hour))
	s.restore(backup.id)
	s.sync(s.owner)
	s.sync(s.partner)
	s.verify(s.quiesce(false))
	truth := s.serverTruth()
	if !covered(truth, child, napStart, napStart.Add(time.Hour)) {
		t.Errorf("the acknowledged nap at %s is missing after restore replay", napStart.Format(time.RFC3339))
	}
	if !covered(truth, child, nightStart, nightStart.Add(11*time.Hour)) {
		t.Errorf("the night sleep is missing after restore replay")
	}
	if len(s.failures) > 0 {
		t.Errorf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
	for _, v := range truth {
		if v.Type == "sleepSession" && v.End != nil && v.End.Sub(v.Start) > 13*time.Hour {
			t.Errorf("restore replay produced a %s sleep: %s", v.End.Sub(v.Start), describe(v))
		}
	}
}

// Regression: after a restore, Parent B's replayed wake reaches the server
// before Parent A's replayed start of the same sleep. The wake must wait for
// the start instead of becoming a conflict, and the sleep must end correctly.
func TestRestoreReplaysAWakeBeforeAnotherDevicesStart(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(10 * time.Hour))
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	_ = s.clock.Set(s.clock.Now().Add(time.Hour))
	start := s.clock.Now()
	session := s.newID()
	s.act(s.owner, true, func() { s.owner.startSleep(child, session, start, "phone") })
	_ = s.clock.Set(start.Add(90 * time.Minute))
	end := s.clock.Now()
	s.act(s.partner, true, func() { s.partner.endSleep(session, end, "calm", "natural") })
	_ = s.clock.Set(end.Add(30 * time.Minute))
	s.restore(backup.id)
	s.sync(s.partner)
	if s.partner.deferred() != 1 || len(s.partner.conflicts) != 0 {
		t.Fatalf("replayed wake was not deferred: deferred=%d conflicts=%d", s.partner.deferred(), len(s.partner.conflicts))
	}
	s.sync(s.owner)
	s.verify(s.quiesce(false))
	if len(s.failures) > 0 {
		t.Fatalf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
	if s.partner.deferred() != 0 || len(s.partner.conflicts) != 0 {
		t.Fatalf("wake still deferred or in conflict: deferred=%d conflicts=%d", s.partner.deferred(), len(s.partner.conflicts))
	}
	got := s.serverTruth()[key("sleepSession", session)]
	if got == nil || got.End == nil || !got.Start.Equal(start) || !got.End.Equal(end) {
		t.Fatalf("restored sleep = %s, want %s..%s", describe(got), start.Format(time.RFC3339), end.Format(time.RFC3339))
	}
}

// If the start never comes back, the deferred wake becomes a conflict after a
// day of server time instead of waiting forever.
func TestDeferredWakeBecomesAConflictAfterADay(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(10 * time.Hour))
	backup, err := s.backend.Checkpoint()
	if err != nil {
		t.Fatal(err)
	}
	_ = s.clock.Set(s.clock.Now().Add(time.Hour))
	session := s.newID()
	s.act(s.owner, true, func() { s.owner.startSleep(child, session, s.clock.Now(), "phone") })
	_ = s.clock.Set(s.clock.Now().Add(time.Hour))
	s.act(s.partner, true, func() { s.partner.endSleep(session, s.clock.Now(), "calm", "natural") })
	s.owner.dark = true
	s.restore(backup.id)
	s.sync(s.partner)
	if s.partner.deferred() != 1 {
		t.Fatalf("wake was not deferred: %d", s.partner.deferred())
	}
	_ = s.clock.Set(s.clock.Now().Add(23 * time.Hour))
	s.act(s.partner, false, func() { s.partner.upsertSleep(child, s.newID(), s.clock.Now().Add(-time.Hour), s.clock.Now()) })
	if len(s.partner.conflicts) != 0 {
		t.Fatal("wake became a conflict before a day passed")
	}
	_ = s.clock.Set(s.clock.Now().Add(2 * time.Hour))
	s.sync(s.partner)
	if s.partner.deferred() != 0 || len(s.partner.conflicts) != 1 {
		t.Fatalf("after a day: deferred=%d conflicts=%d", s.partner.deferred(), len(s.partner.conflicts))
	}
}

// Reproduction (seed 1, day 32): a caregiver logs a sleep with a wrong end
// that overlaps the next nap. The server merges the nap into it and marks the
// nap superseded. Correcting the end afterwards shrinks the merged session,
// but the superseded nap never comes back.
func TestCorrectingAnOverlongSleepDoesNotLoseTheNapItAbsorbed(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(14 * time.Hour))
	base := s.clock.Now().Add(-4 * time.Hour)
	nap := s.newID()
	s.act(s.owner, true, func() { s.owner.upsertSleep(child, nap, base.Add(90*time.Minute), base.Add(150*time.Minute)) })
	long := s.newID()
	s.act(s.partner, true, func() { s.partner.upsertSleep(child, long, base, base.Add(160*time.Minute)) })
	s.act(s.partner, true, func() { s.partner.upsertSleep(child, long, base, base.Add(time.Hour)) })
	s.verify(s.quiesce(false))
	truth := s.serverTruth()
	if !covered(truth, child, base.Add(90*time.Minute), base.Add(150*time.Minute)) {
		t.Errorf("the nap at %s disappeared after the overlapping sleep was corrected", base.Add(90*time.Minute).Format(time.RFC3339))
	}
	if len(s.failures) > 0 {
		t.Errorf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
}

// Regression: a command deferred because its target does not exist yet is
// applied once the target exists. The server keeps the stored rejection for
// the original command ID, so the device must retry under a new one.
func TestDeferredCommandAppliesOnceItsTargetExists(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	session := s.newID()
	at := s.clock.Now().Add(time.Hour)
	_ = s.clock.Set(at.Add(time.Hour))
	end := at.Add(30 * time.Minute)
	wake := &command{ID: s.newID(), Kind: "endSleep", Expected: int64Pointer(1), CreatedAt: s.clock.Now(), Sleep: &unetonv1.SleepInput{
		Id: session, ChildId: child, StartedAt: timestamppb.New(at), EndedAt: timestamppb.New(end), Source: "phone", WakeMood: "calm", WakeReason: "natural",
	}}
	original := wake.ID
	s.partner.enqueue(wake)
	s.sync(s.partner)
	if s.partner.deferred() != 1 {
		t.Fatalf("wake for an unknown session was not deferred: deferred=%d conflicts=%d", s.partner.deferred(), len(s.partner.conflicts))
	}
	s.act(s.owner, true, func() { s.owner.startSleep(child, session, at, "phone") })
	s.sync(s.partner)
	if s.partner.deferred() != 0 || len(s.partner.pending) != 0 || len(s.partner.conflicts) != 0 {
		t.Fatalf("deferred wake did not apply: deferred=%d pending=%d conflicts=%d", s.partner.deferred(), len(s.partner.pending), len(s.partner.conflicts))
	}
	got := s.serverTruth()[key("sleepSession", session)]
	if got == nil || got.End == nil || !got.End.Equal(end) {
		t.Fatalf("session after the deferred wake = %s, want ended at %s", describe(got), end.Format(time.RFC3339))
	}
	var stored string
	_ = s.backend.Store().DB.QueryRowContext(s.ctx, "select result_json from commands where family_id=? and id=?", s.familyID, original).Scan(&stored)
	if !strings.Contains(stored, "rejected") {
		t.Fatalf("expected the original command ID to keep its stored rejection, got %q", stored)
	}
	s.verify(s.quiesce(false))
	if len(s.failures) > 0 {
		t.Fatalf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
}

// Reproduction (seed 2, day 5, with -deferral-new-id): while a real sleep is
// running, a caregiver logs a mistaken five-minute sleep that starts a minute
// before it, then deletes the mistake.
// The real sleep must survive and remain endable.
func TestDeletingAMistakenEntryKeepsTheRunningSleep(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	_ = s.clock.Set(s.clock.Now().Add(3 * time.Hour))
	start := s.clock.Now()
	real := s.newID()
	s.act(s.owner, true, func() { s.owner.startSleep(child, real, start, "phone") })
	_ = s.clock.Set(start.Add(14 * time.Minute))
	// The entry was meant for the nap before, and starts a minute before the
	// running sleep.
	mistaken := s.newID()
	s.act(s.owner, true, func() { s.owner.upsertSleep(child, mistaken, start.Add(-time.Minute), start.Add(4*time.Minute)) })
	if active := s.owner.activeSleep(child); active == nil || active.ID != real {
		t.Errorf("after the mistaken entry the running sleep shown is %s, want %s", describe(active), real)
	}
	_ = s.clock.Set(start.Add(40 * time.Minute))
	s.act(s.owner, true, func() { s.owner.deleteSleep(mistaken) })
	_ = s.clock.Set(start.Add(2 * time.Hour))
	if active := s.owner.activeSleep(child); active != nil {
		s.act(s.owner, true, func() { s.owner.endSleep(active.ID, s.clock.Now(), "calm", "natural") })
	}
	s.verify(s.quiesce(false))
	if !covered(s.serverTruth(), child, start, start.Add(2*time.Hour)) {
		t.Errorf("the running sleep from %s is gone after deleting the mistaken entry", start.Format(time.RFC3339))
	}
	if len(s.failures) > 0 {
		t.Errorf("invariants failed:\n%s", strings.Join(s.failures, "\n"))
	}
}

// Reproduction (seed 2, day 944 with -second-child-months 20): a restore
// loses Parent B's start, so Parent A's replayed wake is rejected with no
// entity and that rejection is stored under the wake's original command ID.
// B's replay brings the session back and A's retry settles it. A second,
// later restore keeps that stored rejection, and A's journal replays the same
// original command ID again. The server returns the stored rejection with no
// entity although the session now exists, so A defers the wake waiting for a
// target that is already there, until some unrelated family change moves the
// cursor (or a day passes and it becomes a conflict). A stored rejection
// returned again should carry the entity as it is now.
func TestStoredRejectionIsReturnedWithTheCurrentEntity(t *testing.T) {
	s := scenario(t, nil)
	child := s.children[0].id
	session := s.newID()
	at := s.clock.Now().Add(time.Hour)
	_ = s.clock.Set(at.Add(2 * time.Hour))
	wake := &unetonv1.Command{Id: s.newID(), ExpectedRevision: int64Pointer(1), Payload: &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{
		Id: session, EndedAt: timestamppb.New(at.Add(time.Hour)), WakeMood: "unknown", WakeReason: "unknown",
	}}}
	send := func(command *unetonv1.Command) *unetonv1.CommandResult {
		var result *unetonv1.CommandResult
		if err := s.partner.withAuth(s.ctx, func(token string) error {
			response, err := s.client.Sync(s.ctx, authorized(&unetonv1.SyncRequest{FamilyId: s.familyID, Generation: s.backend.Generation(), Commands: []*unetonv1.Command{command}}, token))
			if err == nil {
				result = response.Msg.GetCommandResults()[0]
			}
			return err
		}); err != nil {
			t.Fatal(err)
		}
		return result
	}
	if first := send(wake); first.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || first.GetEntity() != nil {
		t.Fatalf("wake before its start: %v", first)
	}
	s.act(s.owner, true, func() { s.owner.startSleep(child, session, at, "phone") })
	s.act(s.owner, true, func() { s.owner.endSleep(session, at.Add(50*time.Minute), "calm", "natural") })
	again := send(wake)
	if again.GetEntity().GetSleepSession() == nil {
		t.Fatalf("stored rejection returned without the session that now exists: %v", again)
	}
}
