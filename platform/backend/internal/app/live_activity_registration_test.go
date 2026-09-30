package app

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

const (
	registrationSession      = "30000000-0000-4000-8000-000000000001"
	registrationToken        = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	rotatedRegistrationToken = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
)

func registerActivity(f *reminderFixture, session, token string, revision int64) error {
	request := connect.NewRequest(&unetonv1.RegisterLiveActivityRequest{SessionId: session, PushToken: token, ApnsEnvironment: "development", RegistrationRevision: revision})
	authorize(request, f.auth.GetAccessToken())
	_, err := f.client.RegisterLiveActivity(context.Background(), request)
	return err
}

func TestActivityRegistrationBeforeAcknowledgementAndStaleRotation(t *testing.T) {
	f := newReminderFixture(t)
	session := "30000000-0000-4000-8000-000000000009"
	if err := registerActivity(f, session, registrationToken, 1); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("unknown optimistic session registration = %v", err)
	}
	f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000009", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(session, f.childID, f.now, nil, "phone")}}})
	if err := registerActivity(f, session, rotatedRegistrationToken, 3); err != nil {
		t.Fatal(err)
	}
	if err := registerActivity(f, session, registrationToken, 2); connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("stale token registration = %v", err)
	}
	tokens, err := f.s.store.Queries.SessionLiveActivityTokens(context.Background(), session)
	if err != nil || len(tokens) != 1 || tokens[0].Token != rotatedRegistrationToken {
		t.Fatalf("tokens = %+v, %v", tokens, err)
	}
}

func TestStaleDeviceRegistrationCannotUndoTokenOrPreferences(t *testing.T) {
	f := newReminderFixture(t)
	update := func(token string, revision int64, enabled bool) error {
		request := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{ApnsToken: &token, NotificationsEnabled: &enabled, ApnsEnvironment: "development", RegistrationRevision: revision})
		authorize(request, f.auth.GetAccessToken())
		_, err := f.client.UpdateDevicePushSettings(context.Background(), request)
		return err
	}
	if err := update(rotatedRegistrationToken, 3, true); err != nil {
		t.Fatal(err)
	}
	if err := update(registrationToken, 2, false); connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("stale settings = %v", err)
	}
	settings, err := f.s.store.Queries.DevicePushSettings(context.Background(), storedb.DevicePushSettingsParams{ID: f.auth.GetDeviceId(), UserID: f.auth.GetUserId()})
	if err != nil || settings.ApnsToken.String != rotatedRegistrationToken || settings.NotificationsEnabled != 1 {
		t.Fatalf("settings = %+v, %v", settings, err)
	}
}

func TestLateActivityTokenQueuesOneDurableEndAndPreservesRotationDuringSend(t *testing.T) {
	f := newReminderFixture(t)
	ctx := context.Background()
	if err := registerActivity(f, registrationSession, registrationToken, 1); err != nil {
		t.Fatal(err)
	}
	// Retry after a lost registration response: the queued end is still one row.
	if err := registerActivity(f, registrationSession, registrationToken, 1); err != nil {
		t.Fatal(err)
	}
	var queued int
	if err := f.s.store.DB.QueryRowContext(ctx, "select count(*) from deliveries where id like 'activity-end-%'").Scan(&queued); err != nil || queued != 1 {
		t.Fatalf("late ends = %d, %v", queued, err)
	}
	var sent []string
	f.s.apns.client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		var payload struct {
			APS struct {
				Event string `json:"event"`
			} `json:"aps"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.APS.Event != "end" {
			t.Fatalf("unexpected event %q", payload.APS.Event)
		}
		sent = append(sent, request.URL.Path)
		if len(sent) == 1 {
			if err := registerActivity(f, registrationSession, rotatedRegistrationToken, 2); err != nil {
				t.Fatal(err)
			}
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	sleep := sleepRecord{ID: registrationSession, FamilyID: f.familyID, ChildID: f.childID}
	if err := f.s.deliverSleepChangeToDevice(ctx, f.familyID, "", f.auth.GetDeviceId(), "end", sleep); err != nil {
		t.Fatal(err)
	}
	tokens, err := f.s.store.Queries.SessionLiveActivityTokens(ctx, registrationSession)
	if err != nil || len(tokens) != 1 || tokens[0].Token != rotatedRegistrationToken {
		t.Fatalf("new token erased during old end: %+v, %v", tokens, err)
	}
	if err := f.s.deliverSleepChangeToDevice(ctx, f.familyID, "", f.auth.GetDeviceId(), "end", sleep); err != nil {
		t.Fatal(err)
	}
	if len(sent) != 2 || !strings.HasSuffix(sent[1], rotatedRegistrationToken) {
		t.Fatalf("end requests = %v", sent)
	}
	// End cleanup retains the registration watermark, even after token deletion.
	if err := registerActivity(f, registrationSession, registrationToken, 1); connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("old token resurrected = %v", err)
	}
}

func TestActivityReconciliationSurvivesRestartAndSuppressesEndedSleep(t *testing.T) {
	f := newReminderFixture(t)
	ctx := context.Background()
	session := "30000000-0000-4000-8000-000000000009"
	f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000009", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(session, f.childID, f.now, nil, "phone")}}})
	request := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{PushToStartToken: new(registrationToken), LiveActivitiesEnabled: new(true), ApnsEnvironment: "development", RegistrationRevision: 1})
	authorize(request, f.auth.GetAccessToken())
	if _, err := f.client.UpdateDevicePushSettings(ctx, request); err != nil {
		t.Fatal(err)
	}
	id := "activity-start-" + session + "-" + f.auth.GetDeviceId()
	if claimed, err := f.s.store.Queries.MarkDeliverySending(ctx, id); err != nil || claimed != 1 {
		t.Fatalf("durable reconcile = %d, %v", claimed, err)
	}
	if _, err := f.s.store.Queries.ClaimLiveActivityStart(ctx, storedb.ClaimLiveActivityStartParams{SessionID: session, DeviceID: f.auth.GetDeviceId(), PushToStartToken: registrationToken, CreatedAt: formatTime(f.now)}); err != nil {
		t.Fatal(err)
	}
	if err := f.s.store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := store.Open(f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.s.store = reopened
	if err := f.s.store.Queries.ResetInterruptedLiveActivityStarts(ctx); err != nil {
		t.Fatal(err)
	}
	if err := f.s.store.Queries.ResetSendingDeliveries(ctx); err != nil {
		t.Fatal(err)
	}
	missing, err := f.s.store.Queries.ActiveSleepsMissingFromDevice(ctx, f.auth.GetDeviceId())
	if err != nil || len(missing) != 1 {
		t.Fatalf("interrupted claim not recovered: %+v, %v", missing, err)
	}
	revision := int64(1)
	f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000010", ExpectedRevision: &revision, Payload: &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{Id: session, EndedAt: timestamppb.New(f.now.Add(time.Minute))}}})
	f.s.apns.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("stale start was sent after sleep ended")
		return nil, nil
	})}
	if err := f.s.startMissingLiveActivities(ctx, f.auth.GetDeviceId(), session); err != nil {
		t.Fatal(err)
	}
	if err := f.s.deliverSleepChange(ctx, f.familyID, "other", "start", sleepRecord{ID: session}); err != nil {
		t.Fatal(err)
	}
}

func TestActivityReconciliationRechecksDevicePreferenceAndMembership(t *testing.T) {
	for _, boundary := range []string{"disabled", "removed"} {
		t.Run(boundary, func(t *testing.T) {
			f := newReminderFixture(t)
			ctx := context.Background()
			session := "30000000-0000-4000-8000-000000000009"
			f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000009", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(session, f.childID, f.now, nil, "phone")}}})
			request := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{PushToStartToken: new(registrationToken), LiveActivitiesEnabled: new(true), ApnsEnvironment: "development", RegistrationRevision: 1})
			authorize(request, f.auth.GetAccessToken())
			if _, err := f.client.UpdateDevicePushSettings(ctx, request); err != nil {
				t.Fatal(err)
			}
			if boundary == "disabled" {
				request.Msg.LiveActivitiesEnabled = new(false)
				request.Msg.RegistrationRevision = 2
				if _, err := f.client.UpdateDevicePushSettings(ctx, request); err != nil {
					t.Fatal(err)
				}
			} else {
				caregiver := authenticate(t, context.Background(), f.client, "Caregiver", "00000000-0000-4000-8000-000000000002")
				inviteRequest := connect.NewRequest(&unetonv1.CreateInviteRequest{FamilyId: f.familyID})
				authorize(inviteRequest, f.auth.GetAccessToken())
				invite, err := f.client.CreateInvite(context.Background(), inviteRequest)
				if err != nil {
					t.Fatal(err)
				}
				accept := connect.NewRequest(&unetonv1.AcceptInviteRequest{Token: invite.Msg.GetToken()})
				authorize(accept, caregiver.GetAccessToken())
				if _, err := f.client.AcceptInvite(context.Background(), accept); err != nil {
					t.Fatal(err)
				}
				transfer := connect.NewRequest(&unetonv1.TransferFamilyOwnershipRequest{FamilyId: f.familyID, UserId: caregiver.GetUserId()})
				authorize(transfer, f.auth.GetAccessToken())
				if _, err := f.client.TransferFamilyOwnership(context.Background(), transfer); err != nil {
					t.Fatal(err)
				}
				remove := connect.NewRequest(&unetonv1.RemoveFamilyMemberRequest{FamilyId: f.familyID, UserId: f.auth.GetUserId()})
				authorize(remove, caregiver.GetAccessToken())
				if _, err := f.client.RemoveFamilyMember(context.Background(), remove); err != nil {
					t.Fatal(err)
				}
			}
			f.s.apns.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
				t.Fatal("ineligible activity start was submitted")
				return nil, nil
			})}
			if err := f.s.startMissingLiveActivities(ctx, f.auth.GetDeviceId(), session); err != nil {
				t.Fatal(err)
			}
			if boundary == "removed" {
				if err := registerActivity(f, session, registrationToken, 1); connect.CodeOf(err) != connect.CodePermissionDenied {
					t.Fatalf("removed caregiver registered token: %v", err)
				}
			}
		})
	}
}
