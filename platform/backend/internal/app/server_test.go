package app

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func TestFamilySyncAndInvite(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	server := httptest.NewServer(NewServer(Config{Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true, Now: func() time.Time { return now }}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	ctx := context.Background()

	owner := authenticate(t, ctx, client, "Owner", "00000000-0000-4000-8000-000000000001")
	apnsToken := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	notificationsEnabled, liveActivitiesEnabled, reminderLead := false, true, int32(30)
	pushSettings := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{
		ApnsToken: &apnsToken, ApnsEnvironment: "development",
		NotificationsEnabled: &notificationsEnabled, LiveActivitiesEnabled: &liveActivitiesEnabled,
		ReminderLeadMinutes: &reminderLead,
	})
	authorize(pushSettings, owner.GetAccessToken())
	settingsResponse, err := client.UpdateDevicePushSettings(ctx, pushSettings)
	if err != nil || settingsResponse.Msg.GetSettings().GetNotificationsEnabled() || settingsResponse.Msg.GetSettings().GetReminderLeadMinutes() != 30 {
		t.Fatalf("device push settings response = %+v, error = %v", settingsResponse, err)
	}
	familyID := "10000000-0000-4000-8000-000000000001"
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Home"})
	authorize(createFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, createFamily); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CreateFamily(ctx, createFamily); err != nil {
		t.Fatalf("idempotent family retry failed: %v", err)
	}

	childID := "20000000-0000-4000-8000-000000000001"
	sessionID := "30000000-0000-4000-8000-000000000001"
	if err := database.Queries.CreateGrowthReferencePoint(ctx, storedb.CreateGrowthReferencePointParams{Reference: "girl", Metric: "height", AgeMonths: 6, Sd: 0, Value: 676}); err != nil {
		t.Fatal(err)
	}
	first := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID,
		Commands: []*unetonv1.Command{
			{Id: "40000000-0000-4000-8000-000000000001", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Muru", BirthDate: "2026-02-23", GrowthReference: "girl"}}}},
			{Id: "40000000-0000-4000-8000-000000000002", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sessionID, childID, time.Date(2026, 8, 23, 9, 0, 0, 0, time.UTC), nil, "phone")}}},
		},
	})
	if len(first.GetEvents()) != 2 || first.GetNextCursor() == 0 {
		t.Fatalf("unexpected first sync: %+v", first)
	}
	if first.GetEvents()[0].GetEntity().GetChild().GetGrowthReference() != "girl" {
		t.Fatalf("child growth reference did not round-trip: %+v", first.GetEvents()[0].GetEntity().GetChild())
	}
	if len(first.GetGrowthReferencePoints()) != 1 || first.GetGrowthReferencePoints()[0].GetValue() != 676 {
		t.Fatalf("growth reference bootstrap did not round-trip: %+v", first.GetGrowthReferencePoints())
	}
	if first.GetSleepForecast().GetActiveSleepId() != sessionID || first.GetSleepForecast().GetWakeEstimate() == nil || first.GetSleepForecast().GetNextSleepEstimate() == nil || !first.GetSleepForecast().GetNextSleepIsProvisional() {
		t.Fatalf("active sleep forecast is incomplete: %+v", first.GetSleepForecast())
	}
	activityToken := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	registerActivity := connect.NewRequest(&unetonv1.RegisterLiveActivityRequest{SessionId: sessionID, PushToken: activityToken, ApnsEnvironment: "development"})
	authorize(registerActivity, owner.GetAccessToken())
	if _, err := client.RegisterLiveActivity(ctx, registerActivity); err != nil {
		t.Fatal(err)
	}
	var registeredActivities int
	if err := database.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM live_activity_tokens WHERE session_id=? AND device_id=?", sessionID, owner.GetDeviceId()).Scan(&registeredActivities); err != nil || registeredActivities != 1 {
		t.Fatalf("registered live activities = %d, error = %v", registeredActivities, err)
	}

	replayed := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: first.GetNextCursor(),
		Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000002", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sessionID, childID, time.Date(2026, 8, 23, 9, 0, 0, 0, time.UTC), nil, "phone")}}}},
	})
	if len(replayed.GetCommandResults()) != 1 || replayed.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || len(replayed.GetEvents()) != 0 {
		t.Fatalf("idempotent replay changed state: %+v", replayed)
	}
	var startDeliveries int
	if err := database.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM deliveries WHERE kind='activityStart'").Scan(&startDeliveries); err != nil || startDeliveries != 1 {
		t.Fatalf("activity start deliveries = %d, error = %v", startDeliveries, err)
	}
	var familyDeliveries int
	if err := database.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM deliveries WHERE kind='familyChanged'").Scan(&familyDeliveries); err != nil || familyDeliveries != 1 {
		t.Fatalf("family change deliveries = %d, error = %v", familyDeliveries, err)
	}

	duplicate := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: first.GetNextCursor(),
		Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000004", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput("30000000-0000-4000-8000-000000000099", childID, time.Date(2026, 8, 23, 9, 5, 0, 0, time.UTC), nil, "watch")}}}},
	})
	if len(duplicate.GetCommandResults()) != 1 || duplicate.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || duplicate.GetCommandResults()[0].GetEntityId() != sessionID || len(duplicate.GetEvents()) != 0 {
		t.Fatalf("duplicate start did not map to canonical session: %+v", duplicate)
	}

	endedAt := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	second := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: first.GetNextCursor(),
		Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000003", Payload: &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{Id: sessionID, EndedAt: timestamppb.New(endedAt)}}}},
	})
	if len(second.GetEvents()) != 1 || second.GetNextSleepEstimate() == nil {
		t.Fatalf("unexpected second sync: %+v", second)
	}
	if second.GetSleepForecast().GetWakeEstimate() != nil || second.GetSleepForecast().GetNextSleepIsProvisional() || second.GetSleepForecast().GetNextSleepEstimate() == nil {
		t.Fatalf("actual wake did not replace provisional forecast: %+v", second.GetSleepForecast())
	}
	var endDeliveries int
	if err := database.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM deliveries WHERE kind='activityEnd'").Scan(&endDeliveries); err != nil || endDeliveries != 1 {
		t.Fatalf("activity end deliveries = %d, error = %v", endDeliveries, err)
	}

	staleRevision := int64(1)
	staleEnd := time.Date(2026, 8, 23, 10, 10, 0, 0, time.UTC)
	stale := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: second.GetNextCursor(),
		Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000005", ExpectedRevision: &staleRevision, Payload: &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: sleepInput(sessionID, childID, time.Date(2026, 8, 23, 9, 10, 0, 0, time.UTC), &staleEnd, "manual")}}}},
	})
	if len(stale.GetCommandResults()) != 1 || stale.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || stale.GetCommandResults()[0].GetEntityId() != sessionID || stale.GetCommandResults()[0].GetEntity() == nil {
		t.Fatalf("stale rejection missing authoritative entity: %+v", stale)
	}

	growthID := "30000000-0000-4000-8000-000000000002"
	weight, height := int32(6_400), int32(640)
	growthInput := &unetonv1.GrowthMeasurementInput{
		Id: growthID, ChildId: childID, MeasuredAt: timestamppb.New(now),
		WeightGrams: &weight, HeightMillimeters: &height, Note: "Neuvola",
	}
	growth := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: stale.GetNextCursor(),
		Commands: []*unetonv1.Command{{
			Id: "40000000-0000-4000-8000-000000000006",
			Payload: &unetonv1.Command_UpsertGrowthMeasurement{
				UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: growthInput},
			},
		}},
	})
	if len(growth.GetEvents()) != 1 || growth.GetEvents()[0].GetEntityType() != unetonv1.EntityType_ENTITY_TYPE_GROWTH_MEASUREMENT || growth.GetEvents()[0].GetEntity().GetGrowthMeasurement().GetWeightGrams() != weight {
		t.Fatalf("growth measurement was not synchronized: %+v", growth)
	}
	staleGrowthRevision := int64(0)
	staleGrowth := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: growth.GetNextCursor(),
		Commands: []*unetonv1.Command{{
			Id: "40000000-0000-4000-8000-000000000007", ExpectedRevision: &staleGrowthRevision,
			Payload: &unetonv1.Command_UpsertGrowthMeasurement{
				UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: &unetonv1.GrowthMeasurementInput{Id: growthID, ChildId: childID, MeasuredAt: timestamppb.New(now), WeightGrams: &weight}},
			},
		}},
	})
	if len(staleGrowth.GetCommandResults()) != 1 || staleGrowth.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || staleGrowth.GetCommandResults()[0].GetEntity().GetGrowthMeasurement().GetRevision() != 1 {
		t.Fatalf("stale growth edit missing authoritative measurement: %+v", staleGrowth)
	}

	childRevision := int64(1)
	growthReferenceUpdate := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID, Cursor: staleGrowth.GetNextCursor(),
		Commands: []*unetonv1.Command{{
			Id: "40000000-0000-4000-8000-000000000008", ExpectedRevision: &childRevision,
			Payload: &unetonv1.Command_UpdateChild{
				UpdateChild: &unetonv1.UpdateChild{Child: &unetonv1.ChildInput{Id: childID, GrowthReference: "boy"}},
			},
		}},
	})
	if len(growthReferenceUpdate.GetCommandResults()) != 1 || growthReferenceUpdate.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || growthReferenceUpdate.GetCommandResults()[0].GetEntity().GetChild().GetGrowthReference() != "boy" {
		t.Fatalf("growth reference update was not synchronized: %+v", growthReferenceUpdate)
	}

	inviteRequest := connect.NewRequest(&unetonv1.CreateInviteRequest{FamilyId: familyID})
	authorize(inviteRequest, owner.GetAccessToken())
	invite, err := client.CreateInvite(ctx, inviteRequest)
	if err != nil {
		t.Fatal(err)
	}
	caregiver := authenticate(t, ctx, client, "Caregiver", "00000000-0000-4000-8000-000000000002")
	accept := connect.NewRequest(&unetonv1.AcceptInviteRequest{Token: invite.Msg.GetToken()})
	authorize(accept, caregiver.GetAccessToken())
	if _, err := client.AcceptInvite(ctx, accept); err != nil {
		t.Fatal(err)
	}
	if _, err := client.AcceptInvite(ctx, accept); err != nil {
		t.Fatalf("idempotent invite retry failed: %v", err)
	}
	caregiverSync := syncFamily(t, ctx, client, caregiver.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID})
	if len(caregiverSync.GetEvents()) != 5 {
		t.Fatalf("caregiver got %d events", len(caregiverSync.GetEvents()))
	}
}

func TestSignOutAndDeleteAccountRevokeSessionsAndOwnedData(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "account.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	server := httptest.NewServer(NewServer(Config{
		Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true,
	}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	ctx := context.Background()
	deviceID := "90000000-0000-4000-8000-000000000001"
	authentication := authenticate(t, ctx, client, "Account owner", deviceID)
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: "91000000-0000-4000-8000-000000000001", Name: "Home"})
	authorize(createFamily, authentication.GetAccessToken())
	if _, err := client.CreateFamily(ctx, createFamily); err != nil {
		t.Fatal(err)
	}

	signOut := connect.NewRequest(&unetonv1.SignOutRequest{})
	authorize(signOut, authentication.GetAccessToken())
	if _, err := client.SignOut(ctx, signOut); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RefreshAuth(ctx, connect.NewRequest(&unetonv1.RefreshAuthRequest{
		DeviceId: deviceID, RefreshToken: authentication.GetRefreshToken(),
	})); err == nil {
		t.Fatal("refresh succeeded after sign out")
	}
	createAfterSignOut := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: "92000000-0000-4000-8000-000000000001"})
	authorize(createAfterSignOut, authentication.GetAccessToken())
	if _, err := client.CreateFamily(ctx, createAfterSignOut); err == nil {
		t.Fatal("access token remained usable after sign out")
	}

	authentication = authenticate(t, ctx, client, "Account owner", deviceID)
	deleteAccount := connect.NewRequest(&unetonv1.DeleteAccountRequest{})
	authorize(deleteAccount, authentication.GetAccessToken())
	if _, err := client.DeleteAccount(ctx, deleteAccount); err != nil {
		t.Fatal(err)
	}
	var families, activeUsers, devices int
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM families").Scan(&families); err != nil {
		t.Fatal(err)
	}
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM users WHERE deleted_at IS NULL").Scan(&activeUsers); err != nil {
		t.Fatal(err)
	}
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM devices").Scan(&devices); err != nil {
		t.Fatal(err)
	}
	if families != 0 || activeUsers != 0 || devices != 0 {
		t.Fatalf("families=%d activeUsers=%d devices=%d", families, activeUsers, devices)
	}
	createAfterDeletion := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: "93000000-0000-4000-8000-000000000001"})
	authorize(createAfterDeletion, authentication.GetAccessToken())
	if _, err := client.CreateFamily(ctx, createAfterDeletion); err == nil {
		t.Fatal("access token remained usable after account deletion")
	}
}

func TestWatchFamilyRecoversAfterServerRestart(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "restart.sqlite")
	database, err := store.Open(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	config := Config{
		Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"),
		Development: true, Now: func() time.Time { return now }, StreamHeartbeat: 10 * time.Millisecond,
	}
	firstServer := httptest.NewServer(NewServer(config).Handler())
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, firstServer.URL)
	ctx := context.Background()
	owner := authenticate(t, ctx, client, "Restart owner", "50000000-0000-4000-8000-000000000001")
	familyID := "51000000-0000-4000-8000-000000000001"
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Restart family"})
	authorize(createFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, createFamily); err != nil {
		t.Fatal(err)
	}
	created := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID,
		Commands: []*unetonv1.Command{{Id: "52000000-0000-4000-8000-000000000001", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: "53000000-0000-4000-8000-000000000001", Nickname: "Muru", BirthDate: "2026-02-23"}}}}},
	})
	firstServer.Close()
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	database, err = store.Open(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	config.Store = database

	secondServer := httptest.NewServer(NewServer(config).Handler())
	defer secondServer.Close()
	client = unetonv1connect.NewUnetonServiceClient(http.DefaultClient, secondServer.URL)
	watchContext, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	watch := connect.NewRequest(&unetonv1.WatchFamilyRequest{FamilyId: familyID, AfterCursor: 0})
	authorize(watch, owner.GetAccessToken())
	stream, err := client.WatchFamily(watchContext, watch)
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || stream.Msg().GetCursor() != created.GetNextCursor() {
		t.Fatalf("restart catch-up failed: cursor=%d error=%v", stream.Msg().GetCursor(), stream.Err())
	}
	_ = stream.Close()

	heartbeat := connect.NewRequest(&unetonv1.WatchFamilyRequest{FamilyId: familyID, AfterCursor: created.GetNextCursor()})
	authorize(heartbeat, owner.GetAccessToken())
	stream, err = client.WatchFamily(watchContext, heartbeat)
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || stream.Msg().GetCursor() != created.GetNextCursor() {
		t.Fatalf("stream heartbeat failed: cursor=%d error=%v", stream.Msg().GetCursor(), stream.Err())
	}
	_ = stream.Close()
}

func TestRefreshIsSafeToRetryAfterLostResponse(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "refresh.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	server := httptest.NewServer(NewServer(Config{Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true, Now: func() time.Time { return now }}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	authentication := authenticate(t, context.Background(), client, "Refresh owner", "60000000-0000-4000-8000-000000000001")
	for attempt := range 2 {
		response, callErr := client.RefreshAuth(context.Background(), connect.NewRequest(&unetonv1.RefreshAuthRequest{
			DeviceId: authentication.GetDeviceId(), RefreshToken: authentication.GetRefreshToken(),
		}))
		if callErr != nil {
			t.Fatalf("refresh attempt %d: %v", attempt+1, callErr)
		}
		if response.Msg.GetAuthentication().GetRefreshToken() != authentication.GetRefreshToken() {
			t.Fatal("refresh retry unexpectedly rotated the durable token")
		}
	}
}

func TestSyncRejectsUnsafeRequestBounds(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "bounds.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	server := httptest.NewServer(NewServer(Config{Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true, Now: func() time.Time { return now }}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, context.Background(), client, "Bounds owner", "70000000-0000-4000-8000-000000000001")
	familyID := "71000000-0000-4000-8000-000000000001"
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Bounds family"})
	authorize(createFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(context.Background(), createFamily); err != nil {
		t.Fatal(err)
	}

	commands := make([]*unetonv1.Command, 101)
	for index := range commands {
		commands[index] = &unetonv1.Command{Id: newID()}
	}
	request := connect.NewRequest(&unetonv1.SyncRequest{FamilyId: familyID, Commands: commands})
	authorize(request, owner.GetAccessToken())
	if _, err := client.Sync(context.Background(), request); connect.CodeOf(err) != connect.CodeResourceExhausted {
		t.Fatalf("oversized command batch returned %v", err)
	}
	request = connect.NewRequest(&unetonv1.SyncRequest{FamilyId: familyID, Cursor: 1, Generation: database.SyncGeneration})
	authorize(request, owner.GetAccessToken())
	future, err := client.Sync(context.Background(), request)
	if err != nil || !future.Msg.GetResetRequired() || future.Msg.GetSnapshot() == nil {
		t.Fatalf("future cursor did not return a recovery snapshot: response=%+v error=%v", future, err)
	}
	watchContext, cancelWatch := context.WithTimeout(context.Background(), time.Second)
	defer cancelWatch()
	watch := connect.NewRequest(&unetonv1.WatchFamilyRequest{FamilyId: familyID, AfterCursor: 1, Generation: database.SyncGeneration})
	authorize(watch, owner.GetAccessToken())
	stream, err := client.WatchFamily(watchContext, watch)
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || !stream.Msg().GetResetRequired() || stream.Msg().GetCursor() != 0 {
		t.Fatalf("watch did not signal cursor rollback: response=%+v error=%v", stream.Msg(), stream.Err())
	}
	_ = stream.Close()

	duplicateID := newID()
	request = connect.NewRequest(&unetonv1.SyncRequest{
		FamilyId: familyID,
		Commands: []*unetonv1.Command{
			{Id: duplicateID, Payload: &unetonv1.Command_DeleteSleep{DeleteSleep: &unetonv1.DeleteSleep{Id: newID()}}},
			{Id: duplicateID, Payload: &unetonv1.Command_DeleteSleep{DeleteSleep: &unetonv1.DeleteSleep{Id: newID()}}},
		},
	})
	authorize(request, owner.GetAccessToken())
	if _, err := client.Sync(context.Background(), request); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("duplicate command ids returned %v", err)
	}

	invalidID, validID, childID := newID(), newID(), newID()
	batch := &unetonv1.SyncRequest{
		FamilyId: familyID,
		Commands: []*unetonv1.Command{
			{Id: invalidID, Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: newID()}}}},
			{Id: validID, Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Muru", BirthDate: "2026-02-23"}}}},
		},
	}
	response := syncFamily(t, context.Background(), client, owner.GetAccessToken(), batch)
	if len(response.GetCommandResults()) != 2 || response.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || response.GetCommandResults()[1].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || len(response.GetEvents()) != 1 {
		t.Fatalf("poison command blocked batch progress: %+v", response)
	}
	batch.Cursor = response.GetNextCursor()
	replayed := syncFamily(t, context.Background(), client, owner.GetAccessToken(), batch)
	if len(replayed.GetCommandResults()) != 2 || len(replayed.GetEvents()) != 0 {
		t.Fatalf("mixed batch was not safe to replay: %+v", replayed)
	}

	otherFamilyID := newID()
	otherFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: otherFamilyID, Name: "Other family"})
	authorize(otherFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(context.Background(), otherFamily); err != nil {
		t.Fatal(err)
	}
	crossFamily := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: otherFamilyID,
		Commands: []*unetonv1.Command{{
			Id:      newID(),
			Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(newID(), childID, now, nil, "phone")}},
		}},
	})
	if len(crossFamily.GetCommandResults()) != 1 || crossFamily.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || len(crossFamily.GetEvents()) != 0 {
		t.Fatalf("cross-family child reference was accepted: %+v", crossFamily)
	}
}

func TestSyncCompactsHistoryIntoSnapshot(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "snapshot.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	server := httptest.NewServer(NewServer(Config{
		Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true,
		Now: func() time.Time { return now }, SnapshotEventThreshold: 2,
	}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, context.Background(), client, "Snapshot owner", "81000000-0000-4000-8000-000000000001")
	familyID, childID, sleepID := "82000000-0000-4000-8000-000000000001", "83000000-0000-4000-8000-000000000001", "84000000-0000-4000-8000-000000000001"
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Snapshots"})
	authorize(createFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(context.Background(), createFamily); err != nil {
		t.Fatal(err)
	}
	response := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{
		FamilyId: familyID,
		Commands: []*unetonv1.Command{
			{Id: "85000000-0000-4000-8000-000000000001", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Muru", BirthDate: "2026-02-23"}}}},
			{Id: "85000000-0000-4000-8000-000000000002", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sleepID, childID, now, nil, "phone")}}},
		},
	})
	if response.GetSnapshot() == nil || len(response.GetSnapshot().GetEntities()) != 2 || len(response.GetEvents()) != 0 {
		t.Fatalf("compacted response = %+v", response)
	}
	var eventCount, snapshotCount int
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM sync_events WHERE family_id=?", familyID).Scan(&eventCount); err != nil {
		t.Fatal(err)
	}
	if err := database.DB.QueryRow("SELECT COUNT(*) FROM family_sync_snapshots WHERE family_id=?", familyID).Scan(&snapshotCount); err != nil {
		t.Fatal(err)
	}
	if eventCount != 0 || snapshotCount != 1 {
		t.Fatalf("events=%d snapshots=%d", eventCount, snapshotCount)
	}
	late := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: 0, Generation: database.SyncGeneration})
	if late.GetSnapshot() == nil || len(late.GetSnapshot().GetEntities()) != 2 || late.GetNextCursor() != response.GetNextCursor() {
		t.Fatalf("late client did not receive compacted snapshot: %+v", late)
	}
}

func TestSyncRecoveryReplaysAcknowledgedCommandAfterDatabaseRestore(t *testing.T) {
	directory := t.TempDir()
	databasePath := filepath.Join(directory, "restore.sqlite")
	backupPath := filepath.Join(directory, "before-command.sqlite")
	secret := []byte("test-secret-that-is-at-least-thirty-two-bytes")
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	database, err := store.Open(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(NewServer(Config{Store: database, TokenSecret: secret, Development: true, Now: func() time.Time { return now }}).Handler())
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, context.Background(), client, "Restore owner", "86000000-0000-4000-8000-000000000001")
	familyID, childID, sleepID, commandID := "87000000-0000-4000-8000-000000000001", "88000000-0000-4000-8000-000000000001", "89000000-0000-4000-8000-000000000001", "8a000000-0000-4000-8000-000000000001"
	createFamily := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Restore"})
	authorize(createFamily, owner.GetAccessToken())
	if _, err := client.CreateFamily(context.Background(), createFamily); err != nil {
		t.Fatal(err)
	}
	child := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Commands: []*unetonv1.Command{{Id: "8b000000-0000-4000-8000-000000000001", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Muru", BirthDate: "2026-02-23"}}}}}})
	if err := database.DB.QueryRow("PRAGMA wal_checkpoint(TRUNCATE)").Err(); err != nil {
		t.Fatal(err)
	}
	server.Close()
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backupPath, contents, 0o600); err != nil {
		t.Fatal(err)
	}

	database, err = store.Open(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	server = httptest.NewServer(NewServer(Config{Store: database, TokenSecret: secret, Development: true, Now: func() time.Time { return now }}).Handler())
	client = unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	accepted := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: child.GetNextCursor(), Commands: []*unetonv1.Command{{Id: commandID, Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sleepID, childID, now, nil, "phone")}}}}})
	if err := acceptedResult(accepted, commandID); err != nil {
		t.Fatal(err)
	}
	oldGeneration, oldCursor := accepted.GetGeneration(), accepted.GetNextCursor()
	server.Close()
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	contents, err = os.ReadFile(backupPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(databasePath, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(databasePath + ".sync-generation"); err != nil {
		t.Fatal(err)
	}

	database, err = store.Open(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	server = httptest.NewServer(NewServer(Config{Store: database, TokenSecret: secret, Development: true, Now: func() time.Time { return now }}).Handler())
	defer server.Close()
	client = unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	reset := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: oldCursor, Generation: oldGeneration})
	if !reset.GetResetRequired() || reset.GetSnapshot() == nil || reset.GetGeneration() == oldGeneration {
		t.Fatalf("restore did not require recovery: %+v", reset)
	}
	replayed := syncFamily(t, context.Background(), client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: reset.GetNextCursor(), Generation: reset.GetGeneration(), Commands: []*unetonv1.Command{{Id: commandID, Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sleepID, childID, now, nil, "phone")}}}}})
	if err := acceptedResult(replayed, commandID); err != nil {
		t.Fatalf("acknowledged command did not recover: %v", err)
	}
}

func authenticate(t *testing.T, ctx context.Context, client unetonv1connect.UnetonServiceClient, name, deviceID string) *unetonv1.AuthenticationResponse {
	t.Helper()
	response, err := client.DevelopmentAuth(ctx, connect.NewRequest(&unetonv1.DevelopmentAuthRequest{Name: name, DeviceId: deviceID}))
	if err != nil {
		t.Fatal(err)
	}
	return response.Msg.GetAuthentication()
}

func syncFamily(t *testing.T, ctx context.Context, client unetonv1connect.UnetonServiceClient, token string, message *unetonv1.SyncRequest) *unetonv1.SyncResponse {
	t.Helper()
	if message.GetGeneration() == "" {
		probe := connect.NewRequest(&unetonv1.SyncRequest{FamilyId: message.GetFamilyId()})
		authorize(probe, token)
		initial, err := client.Sync(ctx, probe)
		if err != nil {
			t.Fatal(err)
		}
		message.Generation = initial.Msg.GetGeneration()
	}
	request := connect.NewRequest(message)
	authorize(request, token)
	response, err := client.Sync(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	return response.Msg
}

func acceptedResult(response *unetonv1.SyncResponse, commandID string) error {
	for _, result := range response.GetCommandResults() {
		if result.GetId() == commandID && result.GetStatus() == unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED {
			return nil
		}
	}
	return fmt.Errorf("command %s was not accepted: %+v", commandID, response)
}

func authorize[T any](request *connect.Request[T], token string) {
	request.Header().Set("Authorization", "Bearer "+token)
}

func sleepInput(id, childID string, startedAt time.Time, endedAt *time.Time, source string) *unetonv1.SleepInput {
	result := &unetonv1.SleepInput{Id: id, ChildId: childID, StartedAt: timestamppb.New(startedAt), Source: source}
	if endedAt != nil {
		result.EndedAt = timestamppb.New(*endedAt)
	}
	return result
}
