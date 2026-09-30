package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

type reminderFixture struct {
	t                       *testing.T
	s                       *Server
	client                  unetonv1connect.UnetonServiceClient
	auth                    *unetonv1.AuthenticationResponse
	now                     time.Time
	path, familyID, childID string
	calls                   int
	fail                    bool
	language                string
}

func newReminderFixture(t *testing.T) *reminderFixture {
	t.Helper()
	f := &reminderFixture{
		t: t, now: time.Date(2026, 9, 30, 10, 0, 0, 0, time.UTC),
		path: filepath.Join(t.TempDir(), "reminders.sqlite"), familyID: "10000000-0000-4000-8000-000000000001", childID: "20000000-0000-4000-8000-000000000001", language: "en",
	}
	db, err := store.Open(f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.s = NewServer(Config{
		Store: db, Development: true, Now: func() time.Time { return f.now }, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"),
		APNS: APNSConfig{TeamID: "team", KeyID: "key", PrivateKey: applePrivateKey(t), Topic: "solutions.bytesized.uneton"},
	})
	t.Cleanup(func() { _ = f.s.store.Close() })
	f.s.apns.endpoint = func(string) string { return "https://apns.test" }
	f.s.apns.now = func() time.Time { return f.now }
	f.s.apns.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		f.calls++
		expiry, parseErr := strconv.ParseInt(r.Header.Get("apns-expiration"), 10, 64)
		if parseErr != nil || expiry > f.now.Add(5*time.Minute).Unix() {
			t.Error("reminder must have a short expiry")
		}
		var payload struct {
			APS struct {
				Alert struct {
					Title string `json:"title"`
					Body  string `json:"body"`
				} `json:"alert"`
			} `json:"aps"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		want := "Sleep window is approaching"
		if f.language == "fi" {
			want = "Uniaika lähestyy"
		}
		if payload.APS.Alert.Title != want || payload.APS.Alert.Body == "" {
			t.Errorf("unexpected reminder copy: %+v", payload)
		}
		if f.fail {
			return nil, errors.New("response lost after possible APNs acceptance")
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	httpServer := httptest.NewServer(f.s.Handler())
	t.Cleanup(httpServer.Close)
	f.client = unetonv1connect.NewUnetonServiceClient(http.DefaultClient, httpServer.URL)
	f.auth = authenticate(t, context.Background(), f.client, "Owner", "00000000-0000-4000-8000-000000000001")
	request := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: f.familyID, Name: "Home"})
	authorize(request, f.auth.GetAccessToken())
	if _, err := f.client.CreateFamily(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	interval := int32(120)
	response := f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000001", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{
		Id: f.childID, Nickname: "Baby", BirthDate: "2026-03-30", PredictionMode: "manual", ManualIntervalMinutes: &interval, TimeZone: "Europe/Helsinki",
	}}}},
		&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000002", Payload: &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: sleepInput("30000000-0000-4000-8000-000000000001", f.childID, f.now.Add(-time.Hour), &f.now, "manual")}}})
	if response.GetSleepForecast().GetNextSleepEstimate() == nil {
		t.Fatal("missing awake forecast")
	}
	f.settings(true, 15, f.now.Add(24*time.Hour))
	return f
}

func (f *reminderFixture) sync(commands ...*unetonv1.Command) *unetonv1.SyncResponse {
	f.t.Helper()
	response := syncFamily(f.t, context.Background(), f.client, f.auth.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: f.familyID, Commands: commands})
	for _, result := range response.GetCommandResults() {
		if result.GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_ACCEPTED {
			f.t.Fatalf("command rejected: %v", result)
		}
	}
	return response
}

func (f *reminderFixture) settings(enabled bool, lead int32, until time.Time) *unetonv1.DevicePushSettings {
	f.t.Helper()
	token, live := strings.Repeat("a", 64), false
	request := connect.NewRequest(&unetonv1.UpdateDevicePushSettingsRequest{
		ApnsToken: &token, ApnsEnvironment: "development", NotificationsEnabled: &enabled,
		LiveActivitiesEnabled: &live, ReminderLeadMinutes: &lead, RemoteRemindersUntil: timestamppb.New(until), NotificationLanguage: &f.language,
	})
	authorize(request, f.auth.GetAccessToken())
	response, err := f.client.UpdateDevicePushSettings(context.Background(), request)
	if err != nil {
		f.t.Fatal(err)
	}
	return response.Msg.GetSettings()
}

func (f *reminderFixture) schedule() {
	f.t.Helper()
	if err := f.s.reconcileSleepReminders(context.Background()); err != nil {
		f.t.Fatal(err)
	}
}

func (f *reminderFixture) due() time.Time {
	f.t.Helper()
	prediction := f.s.sleepForecast(context.Background(), f.familyID).NextSleepEstimate
	if prediction == nil {
		f.t.Fatal("missing prediction")
	}
	return prediction.TargetAt.Add(-15 * time.Minute)
}

func TestRemoteReminderSurvivesRestartAndLostResponse(t *testing.T) {
	f := newReminderFixture(t)
	f.schedule()
	due := f.due()
	if err := f.s.store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := store.Open(f.path)
	if err != nil {
		t.Fatal(err)
	}
	f.s.store = reopened
	f.now = due
	f.fail = true
	f.s.sendDueSleepReminders(context.Background())
	f.schedule()
	f.s.sendDueSleepReminders(context.Background())
	if f.calls != 1 {
		t.Fatalf("ambiguous submission count = %d", f.calls)
	}
}

func TestRemoteReminderUsesLanguageAndLeadTime(t *testing.T) {
	f := newReminderFixture(t)
	f.language = "fi"
	settings := f.settings(true, 30, f.now.Add(24*time.Hour))
	if settings.GetRemoteRemindersUntil() == nil {
		t.Fatal("missing ownership acknowledgement")
	}
	f.schedule()
	f.now = f.due().Add(-15 * time.Minute)
	f.s.sendDueSleepReminders(context.Background())
	if f.calls != 1 {
		t.Fatalf("reminder count = %d", f.calls)
	}
}

func TestRemoteReminderRechecksStateImmediatelyBeforeSend(t *testing.T) {
	for _, change := range []string{"sleep", "disabled", "lease", "lead", "removed", "deleted-family", "deleted-child", "stale"} {
		t.Run(change, func(t *testing.T) {
			f := newReminderFixture(t)
			f.schedule()
			due := f.due()
			switch change {
			case "sleep":
				f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000003", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput("30000000-0000-4000-8000-000000000002", f.childID, f.now, nil, "phone")}}})
			case "disabled":
				f.settings(false, 15, f.now.Add(24*time.Hour))
			case "lease":
				f.settings(true, 15, f.now.Add(time.Minute))
			case "lead":
				f.settings(true, 0, f.now.Add(24*time.Hour))
			case "removed":
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
			case "deleted-family":
				request := connect.NewRequest(&unetonv1.DeleteFamilyRequest{FamilyId: f.familyID})
				authorize(request, f.auth.GetAccessToken())
				if _, err := f.client.DeleteFamily(context.Background(), request); err != nil {
					t.Fatal(err)
				}
			case "deleted-child":
				revision := int64(1)
				f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000003", ExpectedRevision: &revision, Payload: &unetonv1.Command_DeleteChild{DeleteChild: &unetonv1.DeleteChild{Id: f.childID}}})
			case "stale":
				due = due.Add(6 * time.Minute)
			}
			f.now = due
			// Deliberately omit reconciliation: a queued reminder must validate anew.
			f.s.sendDueSleepReminders(context.Background())
			if f.calls != 0 {
				t.Fatalf("stale reminder sent after %s", change)
			}
		})
	}
}

func TestReminderOwnershipUnavailableWithoutAPNS(t *testing.T) {
	f := newReminderFixture(t)
	f.s.apns = nil
	settings := f.settings(true, 15, f.now.Add(24*time.Hour))
	if settings.GetRemoteRemindersUntil() != nil {
		t.Fatal("server without APNs must retain local fallback")
	}
}

func TestRemoteReminderDoesNotBackfillAfterLocalOwnership(t *testing.T) {
	f := newReminderFixture(t)
	due := f.due()
	// Release remote ownership so the phone can cover this window locally.
	f.settings(true, 15, time.Unix(0, 0))
	f.now = due.Add(time.Minute)
	f.auth = authenticate(t, context.Background(), f.client, "Owner", "00000000-0000-4000-8000-000000000001")
	f.settings(true, 15, f.now.Add(24*time.Hour))
	f.schedule()
	f.s.sendDueSleepReminders(context.Background())
	if f.calls != 0 {
		t.Fatal("handoff duplicated a possibly delivered local reminder")
	}
}

func TestRemoteReminderWithZeroLeadFiresAtTarget(t *testing.T) {
	f := newReminderFixture(t)
	f.settings(true, 0, f.now.Add(24*time.Hour))
	f.schedule()
	f.now = f.due().Add(15 * time.Minute)
	f.s.sendDueSleepReminders(context.Background())
	if f.calls != 1 {
		t.Fatalf("zero-lead reminder count = %d", f.calls)
	}
}

func TestRemoteRemindersCoverEachBaby(t *testing.T) {
	f := newReminderFixture(t)
	childID := "20000000-0000-4000-8000-000000000002"
	interval := int32(120)
	f.sync(&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000003", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{
		Id: childID, Nickname: "Sibling", BirthDate: "2026-03-30", PredictionMode: "manual", ManualIntervalMinutes: &interval, TimeZone: "Europe/Helsinki",
	}}}},
		&unetonv1.Command{Id: "40000000-0000-4000-8000-000000000004", Payload: &unetonv1.Command_UpsertSleep{UpsertSleep: &unetonv1.UpsertSleep{Sleep: sleepInput("30000000-0000-4000-8000-000000000002", childID, f.now.Add(-time.Hour), &f.now, "manual")}}})
	f.schedule()
	f.now = f.due()
	f.s.sendDueSleepReminders(context.Background())
	if f.calls != 2 {
		t.Fatalf("two babies produced %d reminders", f.calls)
	}
}
