package app

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

type hardeningFixture struct {
	ctx      context.Context
	db       *store.Store
	server   *Server
	client   unetonv1connect.UnetonServiceClient
	token    string
	familyID string
	childID  string
	cursor   int64
}

func newHardeningFixture(t *testing.T) *hardeningFixture {
	t.Helper()
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "sync.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	server := NewServer(Config{Store: db, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true})
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, httpServer.URL)
	owner := authenticate(t, ctx, client, "Owner", newID())
	familyID, childID := newID(), newID()
	create := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Home"})
	authorize(create, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, create); err != nil {
		t.Fatal(err)
	}
	fixture := &hardeningFixture{ctx: ctx, db: db, server: server, client: client, token: owner.GetAccessToken(), familyID: familyID, childID: childID}
	fixture.mustAccept(t, &unetonv1.Command{Id: newID(), Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Baby", BirthDate: "2026-03-01"}}}})
	return fixture
}

func (f *hardeningFixture) sync(t *testing.T, commands ...*unetonv1.Command) *unetonv1.SyncResponse {
	t.Helper()
	response := syncFamily(t, f.ctx, f.client, f.token, &unetonv1.SyncRequest{FamilyId: f.familyID, Cursor: f.cursor, Commands: commands})
	f.cursor = response.GetNextCursor()
	return response
}

func (f *hardeningFixture) mustAccept(t *testing.T, command *unetonv1.Command) *unetonv1.CommandResult {
	t.Helper()
	response := f.sync(t, command)
	if err := acceptedResult(response, command.GetId()); err != nil {
		t.Fatal(err)
	}
	return response.GetCommandResults()[0]
}

func upsertSleepCommand(id, childID string, start, end time.Time, expected *int64) *unetonv1.Command {
	return &unetonv1.Command{Id: newID(), ExpectedRevision: expected, Payload: &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: sleepInput(id, childID, start, &end, "manual")}}}
}

func TestUpsertMergesEveryOverlappingSessionIntoOneCanonicalSession(t *testing.T) {
	f := newHardeningFixture(t)
	base := time.Date(2026, time.September, 1, 10, 0, 0, 0, time.UTC)
	first, second, bridge := newID(), newID(), newID()
	f.mustAccept(t, upsertSleepCommand(first, f.childID, base, base.Add(time.Hour), nil))
	f.mustAccept(t, upsertSleepCommand(second, f.childID, base.Add(90*time.Minute), base.Add(150*time.Minute), nil))
	// The bridge overlaps both, so all three are one sleep ending at the latest end.
	f.mustAccept(t, upsertSleepCommand(bridge, f.childID, base.Add(30*time.Minute), base.Add(105*time.Minute), nil))

	reset := syncFamily(t, f.ctx, f.client, f.token, &unetonv1.SyncRequest{FamilyId: f.familyID, Generation: "stale"})
	visible := map[string]*unetonv1.SleepSession{}
	superseded := map[string]string{}
	for _, entity := range reset.GetSnapshot().GetEntities() {
		session := entity.GetEntity().GetSleepSession()
		if session == nil {
			continue
		}
		if session.SupersededById != nil {
			superseded[session.GetId()] = session.GetSupersededById()
		} else {
			visible[session.GetId()] = session
		}
	}
	canonical, ok := visible[first]
	if len(visible) != 1 || !ok {
		t.Fatalf("visible sessions = %v, want only %s", visible, first)
	}
	if !canonical.GetStartedAt().AsTime().Equal(base) || !canonical.GetEndedAt().AsTime().Equal(base.Add(150*time.Minute)) {
		t.Fatalf("canonical interval = %v - %v", canonical.GetStartedAt().AsTime(), canonical.GetEndedAt().AsTime())
	}
	if superseded[second] != first || superseded[bridge] != first {
		t.Fatalf("superseded = %v, want both merged into %s", superseded, first)
	}
}

func TestUpsertCannotEditTombstonesOrMoveSessionsBetweenChildren(t *testing.T) {
	f := newHardeningFixture(t)
	start := time.Date(2026, time.September, 1, 10, 0, 0, 0, time.UTC)
	sleepID, growthID, otherChildID := newID(), newID(), newID()
	f.mustAccept(t, &unetonv1.Command{Id: newID(), Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: otherChildID, Nickname: "Twin", BirthDate: "2026-03-01"}}}})
	f.mustAccept(t, upsertSleepCommand(sleepID, f.childID, start, start.Add(time.Hour), nil))
	moved := f.sync(t, upsertSleepCommand(sleepID, otherChildID, start, start.Add(time.Hour), new(int64(1))))
	if moved.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED {
		t.Fatalf("session moved to another child: %v", moved.GetCommandResults()[0])
	}
	f.mustAccept(t, &unetonv1.Command{Id: newID(), ExpectedRevision: new(int64(1)), Payload: &unetonv1.Command_DeleteSleep{DeleteSleep: &unetonv1.DeleteSleep{Id: sleepID}}})
	edited := f.sync(t, upsertSleepCommand(sleepID, f.childID, start, start.Add(2*time.Hour), new(int64(2))))
	result := edited.GetCommandResults()[0]
	if result.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || result.GetEntity().GetSleepSession().GetDeletedAt() == nil || len(edited.GetEvents()) != 0 {
		t.Fatalf("deleted sleep was edited: %v", edited)
	}

	weight := int32(6000)
	growth := &unetonv1.GrowthMeasurementInput{Id: growthID, ChildId: f.childID, MeasuredAt: timestamppb.New(start), WeightGrams: &weight}
	f.mustAccept(t, &unetonv1.Command{Id: newID(), Payload: &unetonv1.Command_UpsertGrowthMeasurement{UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: growth}}})
	f.mustAccept(t, &unetonv1.Command{Id: newID(), ExpectedRevision: new(int64(1)), Payload: &unetonv1.Command_DeleteGrowthMeasurement{DeleteGrowthMeasurement: &unetonv1.DeleteGrowthMeasurement{Id: growthID}}})
	revived := f.sync(t, &unetonv1.Command{Id: newID(), ExpectedRevision: new(int64(2)), Payload: &unetonv1.Command_UpsertGrowthMeasurement{UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: growth}}})
	if revived.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || len(revived.GetEvents()) != 0 {
		t.Fatalf("deleted measurement was edited: %v", revived)
	}
}

func TestSyncAnnouncesTheCommittedCursorOnlyForNewEvents(t *testing.T) {
	f := newHardeningFixture(t)
	updates, cancel := f.server.broker.subscribe(f.familyID)
	defer cancel()
	f.sync(t)
	select {
	case cursor := <-updates:
		t.Fatalf("read-only sync announced cursor %d", cursor)
	default:
	}
	start := time.Date(2026, time.September, 1, 10, 0, 0, 0, time.UTC)
	for range 3 {
		f.mustAccept(t, upsertSleepCommand(newID(), f.childID, start, start.Add(time.Hour), nil))
		start = start.Add(3 * time.Hour)
	}
	for len(updates) > 0 {
		<-updates
	}
	// A caller far behind, reading one event per page, still announces the newest cursor.
	behind := syncFamily(t, f.ctx, f.client, f.token, &unetonv1.SyncRequest{FamilyId: f.familyID, Cursor: 0, Limit: 1, Commands: []*unetonv1.Command{
		upsertSleepCommand(newID(), f.childID, start, start.Add(time.Hour), nil),
	}})
	latest, err := f.db.Queries.LatestFamilyCursor(f.ctx, f.familyID)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case cursor := <-updates:
		if cursor != latest || behind.GetNextCursor() >= latest {
			t.Fatalf("announced %d, latest %d, page %d", cursor, latest, behind.GetNextCursor())
		}
	case <-time.After(time.Second):
		t.Fatal("mutation was not announced")
	}
}

func TestSignInWithAnotherAccountDoesNotInheritDeviceState(t *testing.T) {
	f := newHardeningFixture(t)
	deviceID := newID()
	first := authenticate(t, f.ctx, f.client, "First", deviceID)
	settings := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{ApnsToken: new("aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00aa00"), ApnsEnvironment: "production"})
	authorize(settings, first.GetAccessToken())
	if _, err := f.client.UpdateDevicePushSettings(f.ctx, settings); err != nil {
		t.Fatal(err)
	}
	second := authenticate(t, f.ctx, f.client, "Second", deviceID)
	if second.GetUserId() == first.GetUserId() {
		t.Fatal("expected two accounts")
	}
	var token sql.NullString
	var environment string
	if err := f.db.DB.QueryRowContext(f.ctx, `select apns_token, apns_environment from devices where id=?`, deviceID).Scan(&token, &environment); err != nil {
		t.Fatal(err)
	}
	if token.Valid || environment != "development" {
		t.Fatalf("second account inherited push registration: token=%v environment=%s", token, environment)
	}
	// Signing in again as the same account keeps its registration.
	settings = connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{ApnsToken: new("bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00bb00"), ApnsEnvironment: "production"})
	authorize(settings, second.GetAccessToken())
	if _, err := f.client.UpdateDevicePushSettings(f.ctx, settings); err != nil {
		t.Fatal(err)
	}
	authenticate(t, f.ctx, f.client, "Second", deviceID)
	if err := f.db.DB.QueryRowContext(f.ctx, `select apns_token from devices where id=?`, deviceID).Scan(&token); err != nil {
		t.Fatal(err)
	}
	if !token.Valid {
		t.Fatal("same-account sign-in dropped its push registration")
	}
}

func TestAppleKeyCacheThrottlesUnknownKeysAndSurvivesOutages(t *testing.T) {
	t.Parallel()
	appleKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	var fetches atomic.Int32
	var failing atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fetches.Add(1)
		if failing.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "apple-key", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(appleKey.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString([]byte{1, 0, 1}),
		}}})
	}))
	t.Cleanup(server.Close)
	now := time.Date(2026, time.September, 1, 12, 0, 0, 0, time.UTC)
	authenticator := NewAppleAuthenticator(AppleConfig{ClientID: "client"})
	authenticator.keysURL = server.URL
	authenticator.now = func() time.Time { return now }
	token := func(kid string) *jwt.Token { return &jwt.Token{Header: map[string]any{"kid": kid}} }

	if _, err := authenticator.keyForToken(token("apple-key")); err != nil {
		t.Fatal(err)
	}
	for range 5 {
		if _, err := authenticator.keyForToken(token("forged")); err == nil {
			t.Fatal("unknown key accepted")
		}
	}
	if got := fetches.Load(); got != 1 {
		t.Fatalf("fetches = %d, want unknown key IDs throttled to the first fetch", got)
	}
	now = now.Add(2 * time.Hour)
	failing.Store(true)
	if _, err := authenticator.keyForToken(token("apple-key")); err != nil {
		t.Fatalf("cached key unavailable during provider outage: %v", err)
	}
}
