package app

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

func TestSyncRequiresRevisionsAndReturnsCompleteTombstones(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "sync.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	server := httptest.NewServer(NewServer(Config{Store: db, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, ctx, client, "Owner", newID())
	familyID, childID, sleepID, growthID, temperatureID := newID(), newID(), newID(), newID(), newID()
	create := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Home"})
	authorize(create, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, create); err != nil {
		t.Fatal(err)
	}
	startedAt := time.Now().UTC().Add(-time.Hour)
	child := &unetonv1.ChildInput{Id: childID, Nickname: "Baby", BirthDate: "2026-03-01"}
	sleep := sleepInput(sleepID, childID, startedAt, nil, "phone")
	weight := int32(6000)
	growth := &unetonv1.GrowthMeasurementInput{Id: growthID, ChildId: childID, MeasuredAt: timestamppb.New(startedAt), WeightGrams: &weight}
	temperature := &unetonv1.TemperatureReadingInput{Id: temperatureID, ChildId: childID, MeasuredAt: timestamppb.New(startedAt), CentiCelsius: 3700}
	initial := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Commands: []*unetonv1.Command{
		{Id: newID(), Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: child}}},
		{Id: newID(), Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleep}}},
		{Id: newID(), Payload: &unetonv1.Command_UpsertGrowthMeasurement{UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: growth}}},
		{Id: newID(), Payload: &unetonv1.Command_UpsertTemperatureReading{UpsertTemperatureReading: &unetonv1.UpsertTemperatureReading{Reading: temperature}}},
	}})
	for _, result := range initial.GetCommandResults() {
		if result.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED {
			t.Fatalf("seed command rejected: %v", result)
		}
	}
	mutations := []*unetonv1.Command{
		{Payload: &unetonv1.Command_UpdateChild{UpdateChild: &unetonv1.UpdateChild{Child: child}}},
		{Payload: &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{Id: sleepID, EndedAt: timestamppb.New(startedAt.Add(time.Minute))}}},
		{Payload: &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: sleep}}},
		{Payload: &unetonv1.Command_DeleteSleep{DeleteSleep: &unetonv1.DeleteSleep{Id: sleepID}}},
		{Payload: &unetonv1.Command_UpsertGrowthMeasurement{UpsertGrowthMeasurement: &unetonv1.UpsertGrowthMeasurement{Measurement: growth}}},
		{Payload: &unetonv1.Command_DeleteGrowthMeasurement{DeleteGrowthMeasurement: &unetonv1.DeleteGrowthMeasurement{Id: growthID}}},
		{Payload: &unetonv1.Command_UpsertTemperatureReading{UpsertTemperatureReading: &unetonv1.UpsertTemperatureReading{Reading: temperature}}},
		{Payload: &unetonv1.Command_DeleteTemperatureReading{DeleteTemperatureReading: &unetonv1.DeleteTemperatureReading{Id: temperatureID}}},
	}
	for _, mutation := range mutations {
		for _, revision := range []*int64{nil, new(int64(99))} {
			mutation.Id, mutation.ExpectedRevision = newID(), revision
			response := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: initial.GetNextCursor(), Commands: []*unetonv1.Command{mutation}})
			if len(response.GetCommandResults()) != 1 || response.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || len(response.GetEvents()) != 0 || response.GetNextCursor() != initial.GetNextCursor() {
				t.Fatalf("mutation without matching revision changed state: %v: %v", mutation, response)
			}
			retry := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: response.GetNextCursor(), Commands: []*unetonv1.Command{mutation}})
			if !proto.Equal(response.GetCommandResults()[0], retry.GetCommandResults()[0]) {
				t.Fatalf("rejected result changed on retry: %v", retry)
			}
		}
	}
	midnight := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: initial.GetNextCursor(), Commands: []*unetonv1.Command{{
		Id: newID(), ExpectedRevision: new(int64(1)), Payload: &unetonv1.Command_UpdateChild{UpdateChild: &unetonv1.UpdateChild{Child: child}},
	}}})
	settings := midnight.GetCommandResults()[0]
	if settings.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || settings.GetEntity().GetChild().GetQuietHoursStartMinutes() != 0 || settings.GetEntity().GetChild().GetQuietHoursEndMinutes() != 0 {
		t.Fatalf("midnight quiet hours were not stored: %v", settings)
	}
	initial = midnight
	for _, deletion := range []*unetonv1.Command{mutations[3], mutations[5], mutations[7]} {
		deletion.Id, deletion.ExpectedRevision = newID(), new(int64(1))
		response := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: initial.GetNextCursor(), Commands: []*unetonv1.Command{deletion}})
		result := response.GetCommandResults()[0]
		if result.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED || result.GetEntity().GetDeleted() != nil {
			t.Fatalf("delete did not return a complete entity: %v", result)
		}
		entity := result.GetEntity()
		deleted := entity.GetSleepSession().GetDeletedAt() != nil || entity.GetGrowthMeasurement().GetDeletedAt() != nil || entity.GetTemperatureReading().GetDeletedAt() != nil
		if !deleted {
			t.Fatalf("delete missing tombstone: %v", result)
		}
		for _, event := range response.GetEvents() {
			if event.GetEntity().GetDeleted() != nil {
				t.Fatalf("event has an incomplete tombstone: %v", event)
			}
		}
		retry := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: response.GetNextCursor(), Commands: []*unetonv1.Command{deletion}})
		if len(retry.GetEvents()) != 0 || !proto.Equal(result, retry.GetCommandResults()[0]) {
			t.Fatalf("accepted delete was not idempotent: %v", retry)
		}
		initial = response
	}
}
