package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func (s *Server) currentSnapshot(ctx context.Context, tx *sql.Tx, familyID string) (*FamilySnapshot, error) {
	q := s.store.Queries.WithTx(tx)
	stored, err := q.FamilySyncSnapshot(ctx, familyID)
	if err == nil && stored.Generation == s.store.SyncGeneration {
		var entities []SnapshotEntity
		if err := json.Unmarshal(stored.EntitiesJson, &entities); err != nil {
			return nil, fmt.Errorf("decode family snapshot: %w", err)
		}
		createdAt, err := parseTime(stored.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("parse family snapshot time: %w", err)
		}
		return &FamilySnapshot{Cursor: stored.Cursor, Entities: entities, CreatedAt: createdAt}, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("read family snapshot: %w", err)
	}
	return s.buildSnapshot(ctx, tx, familyID, true)
}

func (s *Server) buildSnapshot(ctx context.Context, tx *sql.Tx, familyID string, persist bool) (*FamilySnapshot, error) {
	q := s.store.Queries.WithTx(tx)
	cursor, err := q.LatestFamilyCursor(ctx, familyID)
	if err != nil {
		return nil, fmt.Errorf("read snapshot cursor: %w", err)
	}
	childIDs, err := q.SnapshotChildIDs(ctx, familyID)
	if err != nil {
		return nil, fmt.Errorf("list snapshot children: %w", err)
	}
	sleepIDs, err := q.SnapshotSleepIDs(ctx, familyID)
	if err != nil {
		return nil, fmt.Errorf("list snapshot sleeps: %w", err)
	}
	entities := make([]SnapshotEntity, 0, len(childIDs)+len(sleepIDs))
	for _, id := range childIDs {
		payload, revision, err := childJSON(ctx, tx, familyID, id)
		if err != nil {
			return nil, fmt.Errorf("snapshot child %s: %w", id, err)
		}
		entities = append(entities, SnapshotEntity{EntityType: "child", EntityID: id, Revision: revision, Payload: payload})
	}
	for _, id := range sleepIDs {
		payload, revision, err := sleepJSON(ctx, tx, familyID, id)
		if err != nil {
			return nil, fmt.Errorf("snapshot sleep %s: %w", id, err)
		}
		entities = append(entities, SnapshotEntity{EntityType: "sleepSession", EntityID: id, Revision: revision, Payload: payload})
	}
	createdAt := s.now().UTC()
	encoded, err := json.Marshal(entities)
	if err != nil {
		return nil, fmt.Errorf("encode family snapshot: %w", err)
	}
	if persist {
		if err := q.UpsertFamilySyncSnapshot(ctx, storedb.UpsertFamilySyncSnapshotParams{
			FamilyID: familyID, Generation: s.store.SyncGeneration, Cursor: cursor,
			EntitiesJson: encoded, CreatedAt: formatTime(createdAt),
		}); err != nil {
			return nil, fmt.Errorf("store family snapshot: %w", err)
		}
	}
	return &FamilySnapshot{Cursor: cursor, Entities: entities, CreatedAt: createdAt}, nil
}

func (s *Server) maybeCompactSyncHistory(ctx context.Context, tx *sql.Tx, familyID string) (*FamilySnapshot, error) {
	q := s.store.Queries.WithTx(tx)
	count, err := q.FamilyEventCount(ctx, familyID)
	if err != nil {
		return nil, fmt.Errorf("count family events: %w", err)
	}
	if count < int64(s.snapshotEventThreshold) {
		return nil, nil
	}
	snapshot, err := s.buildSnapshot(ctx, tx, familyID, true)
	if err != nil {
		return nil, err
	}
	if err := q.DeleteFamilyEventsThrough(ctx, storedb.DeleteFamilyEventsThroughParams{FamilyID: familyID, Cursor: snapshot.Cursor}); err != nil {
		return nil, fmt.Errorf("compact family events: %w", err)
	}
	return snapshot, nil
}

func (s *Server) pruneSentDeliveries(ctx context.Context, q *storedb.Queries) {
	_, err := q.DeleteSentDeliveriesBefore(ctx, formatTime(s.now().UTC().Add(-s.deliveryRetention)))
	if err != nil {
		s.logger.Warn("could not prune sent deliveries", "error", err)
	}
}
