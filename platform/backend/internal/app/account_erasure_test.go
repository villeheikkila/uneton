package app

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store"
	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func TestEraseAccountTransfersOwnedFamilyToOldestActiveCaregiver(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "transfer.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if closeErr := database.Close(); closeErr != nil {
			t.Error(closeErr)
		}
	})
	ctx := context.Background()
	createdAt := "2026-08-30T10:00:00Z"
	for _, user := range []struct{ id, subject string }{{"owner", "apple-owner"}, {"successor", "apple-successor"}, {"later", "apple-later"}} {
		if err := database.Queries.CreateUser(ctx, storedb.CreateUserParams{ID: user.id, AppleSubject: user.subject, CreatedAt: createdAt}); err != nil {
			t.Fatal(err)
		}
	}
	if err := database.Queries.CreateFamily(ctx, storedb.CreateFamilyParams{ID: "family", Name: "Home", OwnerID: "owner", CreatedAt: createdAt}); err != nil {
		t.Fatal(err)
	}
	if err := database.Queries.AddOwner(ctx, storedb.AddOwnerParams{FamilyID: "family", UserID: "owner", JoinedAt: createdAt}); err != nil {
		t.Fatal(err)
	}
	if err := database.Queries.AddCaregiver(ctx, storedb.AddCaregiverParams{FamilyID: "family", UserID: "successor", JoinedAt: "2026-08-30T10:01:00Z"}); err != nil {
		t.Fatal(err)
	}
	if err := database.Queries.AddCaregiver(ctx, storedb.AddCaregiverParams{FamilyID: "family", UserID: "later", JoinedAt: "2026-08-30T10:02:00Z"}); err != nil {
		t.Fatal(err)
	}

	server := NewServer(Config{Store: database, TokenSecret: []byte("test-secret-that-is-at-least-thirty-two-bytes"), Now: func() time.Time { return time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC) }})
	if err := server.eraseAccount(ctx, "owner"); err != nil {
		t.Fatal(err)
	}
	family, err := database.Queries.FamilyByID(ctx, "family")
	if err != nil {
		t.Fatal(err)
	}
	if family.OwnerID != "successor" {
		t.Fatalf("owner = %q, want successor", family.OwnerID)
	}
	isOwner, err := database.Queries.HasFamilyRole(ctx, storedb.HasFamilyRoleParams{FamilyID: "family", UserID: "successor", Role: "owner"})
	if err != nil || !isOwner {
		t.Fatalf("successor owner role = %t, error = %v", isOwner, err)
	}
	activeOwner, err := database.Queries.UserIDByAppleSubject(ctx, "apple-owner")
	if err == nil || activeOwner != "" {
		t.Fatalf("deleted Apple subject still resolved as %q", activeOwner)
	}
}
