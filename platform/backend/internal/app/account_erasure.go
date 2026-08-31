package app

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

// eraseAccount removes private account data and sessions in one transaction.
// A family survives when another active caregiver can take ownership; otherwise
// cascading foreign keys erase the family and its diary data.
func (s *Server) eraseAccount(ctx context.Context, userID string) error {
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin account erasure: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	q := s.store.Queries.WithTx(tx)
	familyIDs, err := q.OwnedFamilyIDs(ctx, userID)
	if err != nil {
		return fmt.Errorf("list owned families: %w", err)
	}
	for _, familyID := range familyIDs {
		successorID, successorErr := q.FamilyOwnershipSuccessor(ctx, storedb.FamilyOwnershipSuccessorParams{
			FamilyID: familyID,
			OwnerID:  userID,
		})
		switch {
		case errors.Is(successorErr, sql.ErrNoRows):
			rows, deleteErr := q.DeleteFamilyOwnedBy(ctx, storedb.DeleteFamilyOwnedByParams{ID: familyID, OwnerID: userID})
			if deleteErr != nil || rows != 1 {
				return fmt.Errorf("delete family without successor: rows=%d: %w", rows, deleteErr)
			}
		case successorErr != nil:
			return fmt.Errorf("select family successor: %w", successorErr)
		default:
			rows, transferErr := q.TransferFamilyOwnership(ctx, storedb.TransferFamilyOwnershipParams{
				SuccessorID: successorID,
				ID:          familyID,
				OwnerID:     userID,
			})
			if transferErr != nil || rows != 1 {
				return fmt.Errorf("transfer family ownership: rows=%d: %w", rows, transferErr)
			}
			rows, promoteErr := q.PromoteFamilyOwner(ctx, storedb.PromoteFamilyOwnerParams{
				FamilyID: familyID,
				UserID:   successorID,
			})
			if promoteErr != nil || rows != 1 {
				return fmt.Errorf("promote family owner: rows=%d: %w", rows, promoteErr)
			}
		}
	}

	if err := q.RemoveFamilyMemberships(ctx, userID); err != nil {
		return fmt.Errorf("remove family memberships: %w", err)
	}
	if err := q.DeleteUserDevices(ctx, userID); err != nil {
		return fmt.Errorf("delete user devices: %w", err)
	}
	rows, err := q.AnonymizeUser(ctx, storedb.AnonymizeUserParams{
		AppleSubject: "deleted:" + userID + ":" + newID(),
		DeletedAt:    nullString(formatTime(s.now().UTC())),
		ID:           userID,
	})
	if err != nil || rows != 1 {
		return fmt.Errorf("anonymize user: rows=%d: %w", rows, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit account erasure: %w", err)
	}
	return nil
}
