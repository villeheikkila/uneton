package app

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"
	unetonv1 "solutions.bytesized/uneton/internal/gen/uneton/v1"
	"solutions.bytesized/uneton/internal/gen/uneton/v1/unetonv1connect"
	"solutions.bytesized/uneton/platform/backend/internal/store"
)

func TestFamilyManagementPermissionsAndLifecycle(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "family.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	now := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)
	server := httptest.NewServer(NewServer(Config{Store: db, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true, Now: func() time.Time { return now }}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, ctx, client, "Owner", "10000000-0000-4000-8000-000000000001")
	caregiver := authenticate(t, ctx, client, "Caregiver", "10000000-0000-4000-8000-000000000002")
	familyID := "20000000-0000-4000-8000-000000000001"
	create := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "First name"})
	authorize(create, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, create); err != nil {
		t.Fatal(err)
	}

	profile := connect.NewRequest(&unetonv1.UpdateProfileRequest{DisplayName: "  Parent  "})
	authorize(profile, owner.GetAccessToken())
	updated, err := client.UpdateProfile(ctx, profile)
	if err != nil || updated.Msg.GetDisplayName() != "Parent" {
		t.Fatalf("profile: %v %+v", err, updated)
	}
	deniedRename := connect.NewRequest(&unetonv1.RenameFamilyRequest{FamilyId: familyID, Name: "Second name"})
	authorize(deniedRename, caregiver.GetAccessToken())
	if _, err := client.RenameFamily(ctx, deniedRename); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("caregiver renamed family: %v", err)
	}
	rename := connect.NewRequest(&unetonv1.RenameFamilyRequest{FamilyId: familyID, Name: "Second name"})
	authorize(rename, owner.GetAccessToken())
	if _, err := client.RenameFamily(ctx, rename); err != nil {
		t.Fatal(err)
	}
	details := connect.NewRequest(&unetonv1.GetFamilyManagementRequest{FamilyId: familyID})
	authorize(details, owner.GetAccessToken())
	management, err := client.GetFamilyManagement(ctx, details)
	if err != nil || management.Msg.GetFamilyName() != "Second name" || management.Msg.GetMyDisplayName() != "Parent" || len(management.Msg.GetMembers()) != 1 {
		t.Fatalf("management: %v %+v", err, management)
	}

	inviteRequest := connect.NewRequest(&unetonv1.CreateInviteRequest{FamilyId: familyID})
	authorize(inviteRequest, owner.GetAccessToken())
	invite, err := client.CreateInvite(ctx, inviteRequest)
	if err != nil {
		t.Fatal(err)
	}
	management, err = client.GetFamilyManagement(ctx, details)
	if err != nil || len(management.Msg.GetPendingInvites()) != 1 {
		t.Fatalf("pending invite: %v %+v", err, management)
	}
	revoke := connect.NewRequest(&unetonv1.RevokeInviteRequest{FamilyId: familyID, InviteId: management.Msg.GetPendingInvites()[0].GetId()})
	authorize(revoke, owner.GetAccessToken())
	if _, err := client.RevokeInvite(ctx, revoke); err != nil {
		t.Fatal(err)
	}
	revoked := connect.NewRequest(&unetonv1.AcceptInviteRequest{Token: invite.Msg.GetToken()})
	authorize(revoked, caregiver.GetAccessToken())
	if _, err := client.AcceptInvite(ctx, revoked); err == nil {
		t.Fatal("revoked invitation was accepted")
	}

	invite, err = client.CreateInvite(ctx, inviteRequest)
	if err != nil {
		t.Fatal(err)
	}
	accept := connect.NewRequest(&unetonv1.AcceptInviteRequest{Token: invite.Msg.GetToken()})
	authorize(accept, caregiver.GetAccessToken())
	if _, err := client.AcceptInvite(ctx, accept); err != nil {
		t.Fatal(err)
	}
	management, err = client.GetFamilyManagement(ctx, details)
	if err != nil || len(management.Msg.GetMembers()) != 2 {
		t.Fatalf("caregivers: %v %+v", err, management)
	}
	caregiverID := ""
	for _, member := range management.Msg.GetMembers() {
		if member.GetRole() == "caregiver" {
			caregiverID = member.GetUserId()
		}
	}
	if caregiverID == "" {
		t.Fatal("missing caregiver")
	}
	deleteFamily := connect.NewRequest(&unetonv1.DeleteFamilyRequest{FamilyId: familyID})
	authorize(deleteFamily, owner.GetAccessToken())
	if _, err := client.DeleteFamily(ctx, deleteFamily); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("family deleted with caregiver: %v", err)
	}
	transfer := connect.NewRequest(&unetonv1.TransferFamilyOwnershipRequest{FamilyId: familyID, UserId: caregiverID})
	authorize(transfer, owner.GetAccessToken())
	if _, err := client.TransferFamilyOwnership(ctx, transfer); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RenameFamily(ctx, rename); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("former owner still had ownership: %v", err)
	}
	leave := connect.NewRequest(&unetonv1.LeaveFamilyRequest{FamilyId: familyID})
	authorize(leave, owner.GetAccessToken())
	if _, err := client.LeaveFamily(ctx, leave); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetFamilyManagement(ctx, details); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("former caregiver still had access: %v", err)
	}
	authorize(deleteFamily, caregiver.GetAccessToken())
	if _, err := client.DeleteFamily(ctx, deleteFamily); err != nil {
		t.Fatal(err)
	}
	caregiverDetails := connect.NewRequest(&unetonv1.GetFamilyManagementRequest{FamilyId: familyID})
	authorize(caregiverDetails, caregiver.GetAccessToken())
	if _, err := client.GetFamilyManagement(ctx, caregiverDetails); connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("deleted family accessible: %v", err)
	}
}

func TestDeleteChildCommandIsIdempotentAndRevisionChecked(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "child.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	server := httptest.NewServer(NewServer(Config{Store: db, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Development: true}).Handler())
	defer server.Close()
	client := unetonv1connect.NewUnetonServiceClient(http.DefaultClient, server.URL)
	owner := authenticate(t, ctx, client, "Owner", "10000000-0000-4000-8000-000000000003")
	familyID := "20000000-0000-4000-8000-000000000003"
	childID := "30000000-0000-4000-8000-000000000003"
	create := connect.NewRequest(&unetonv1.CreateFamilyRequest{Id: familyID, Name: "Home"})
	authorize(create, owner.GetAccessToken())
	if _, err := client.CreateFamily(ctx, create); err != nil {
		t.Fatal(err)
	}
	first := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000031", Payload: &unetonv1.Command_CreateChild{CreateChild: &unetonv1.CreateChild{Child: &unetonv1.ChildInput{Id: childID, Nickname: "Baby", BirthDate: "2026-03-29"}}}}}})
	if len(first.GetEvents()) != 1 {
		t.Fatalf("create: %+v", first)
	}
	wrong := int64(0)
	stale := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: first.GetNextCursor(), Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000032", ExpectedRevision: &wrong, Payload: &unetonv1.Command_DeleteChild{DeleteChild: &unetonv1.DeleteChild{Id: childID}}}}})
	if stale.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED || len(stale.GetEvents()) != 0 {
		t.Fatalf("stale delete: %+v", stale)
	}
	started := time.Now().UTC().Add(-time.Hour)
	sleepID := "30000000-0000-4000-8000-000000000004"
	active := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: first.GetNextCursor(), Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000034", Payload: &unetonv1.Command_StartSleep{StartSleep: &unetonv1.StartSleep{Sleep: sleepInput(sleepID, childID, started, nil, "phone")}}}}})
	if err := acceptedResult(active, "40000000-0000-4000-8000-000000000034"); err != nil {
		t.Fatal(err)
	}
	revision := int64(1)
	deletion := &unetonv1.Command{Id: "40000000-0000-4000-8000-000000000033", ExpectedRevision: &revision, Payload: &unetonv1.Command_DeleteChild{DeleteChild: &unetonv1.DeleteChild{Id: childID}}}
	blocked := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: active.GetNextCursor(), Commands: []*unetonv1.Command{deletion}})
	if blocked.GetCommandResults()[0].GetStatus() != unetonv1.CommandStatus_COMMAND_STATUS_REJECTED {
		t.Fatalf("active sleep allowed child deletion: %+v", blocked)
	}
	ended := time.Now().UTC()
	woke := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: blocked.GetNextCursor(), Commands: []*unetonv1.Command{{Id: "40000000-0000-4000-8000-000000000035", ExpectedRevision: new(int64(1)), Payload: &unetonv1.Command_EndSleep{EndSleep: &unetonv1.EndSleep{Id: sleepID, EndedAt: timestamppb.New(ended)}}}}})
	if err := acceptedResult(woke, "40000000-0000-4000-8000-000000000035"); err != nil {
		t.Fatal(err)
	}
	deletion.Id = "40000000-0000-4000-8000-000000000036"
	deleted := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: woke.GetNextCursor(), Commands: []*unetonv1.Command{deletion}})
	if err := acceptedResult(deleted, deletion.GetId()); err != nil {
		t.Fatal(err)
	}
	if len(deleted.GetEvents()) != 1 || deleted.GetEvents()[0].GetOperation() != unetonv1.EventOperation_EVENT_OPERATION_DELETE || deleted.GetEvents()[0].GetEntity().GetChild().GetDeletedAt() == nil {
		t.Fatalf("delete event: %+v", deleted)
	}
	retried := syncFamily(t, ctx, client, owner.GetAccessToken(), &unetonv1.SyncRequest{FamilyId: familyID, Cursor: deleted.GetNextCursor(), Commands: []*unetonv1.Command{deletion}})
	if err := acceptedResult(retried, deletion.GetId()); err != nil {
		t.Fatal(err)
	}
	if len(retried.GetEvents()) != 0 {
		t.Fatalf("retry appended event: %+v", retried)
	}
}
