package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
	_ "time/tzdata"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
	"solutions.bytesized/uneton/platform/backend/internal/sweetspot"
)

type childPayload struct {
	ID                     string `json:"id"`
	Nickname               string `json:"nickname"`
	BirthDate              string `json:"birthDate"`
	PredictionMode         string `json:"predictionMode,omitempty"`
	ManualIntervalMinutes  *int   `json:"manualIntervalMinutes,omitempty"`
	QuietHoursStartMinutes int    `json:"quietHoursStartMinutes,omitempty"`
	QuietHoursEndMinutes   int    `json:"quietHoursEndMinutes,omitempty"`
	TimeZone               string `json:"timeZone,omitempty"`
}

type sleepPayload struct {
	ID                  string     `json:"id"`
	ChildID             string     `json:"childID"`
	StartedAt           time.Time  `json:"startedAt"`
	EndedAt             *time.Time `json:"endedAt,omitempty"`
	Source              string     `json:"source,omitempty"`
	StartCondition      string     `json:"startCondition,omitempty"`
	SleepLocation       string     `json:"sleepLocation,omitempty"`
	EndCondition        string     `json:"endCondition,omitempty"`
	WakeMood            string     `json:"wakeMood,omitempty"`
	WakeReason          string     `json:"wakeReason,omitempty"`
	CaregiverIntervened *bool      `json:"caregiverIntervened,omitempty"`
}

type sleepRecord struct {
	ID                  string     `json:"id"`
	FamilyID            string     `json:"familyID"`
	ChildID             string     `json:"childID"`
	StartedAt           time.Time  `json:"startedAt"`
	EndedAt             *time.Time `json:"endedAt,omitempty"`
	Revision            int        `json:"revision"`
	AuthorID            string     `json:"authorID"`
	Source              string     `json:"source"`
	StartCondition      string     `json:"startCondition,omitempty"`
	SleepLocation       string     `json:"sleepLocation,omitempty"`
	EndCondition        string     `json:"endCondition,omitempty"`
	WakeMood            string     `json:"wakeMood"`
	WakeReason          string     `json:"wakeReason"`
	CaregiverIntervened *bool      `json:"caregiverIntervened,omitempty"`
	SupersededByID      *string    `json:"supersededByID,omitempty"`
	UpdatedAt           time.Time  `json:"updatedAt"`
	DeletedAt           *time.Time `json:"deletedAt,omitempty"`
}

type activityDelivery struct {
	OriginDeviceID string      `json:"originDeviceID,omitempty"`
	Sleep          sleepRecord `json:"sleep"`
}

type familyDelivery struct {
	OriginDeviceID string `json:"originDeviceID,omitempty"`
}

func (s *Server) synchronize(ctx context.Context, familyID, userID string, request SyncRequest) (SyncResponse, error) {
	request.Limit = boundedLimit(request.Limit)
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return SyncResponse{}, err
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	latestCursor, err := q.LatestFamilyCursor(ctx, familyID)
	if err != nil {
		return SyncResponse{}, fmt.Errorf("read latest family cursor: %w", err)
	}
	if request.Generation != s.store.SyncGeneration || request.Cursor > latestCursor {
		snapshot, err := s.buildSnapshot(ctx, tx, familyID, false)
		if err != nil {
			return SyncResponse{}, err
		}
		if err := tx.Commit(); err != nil {
			return SyncResponse{}, err
		}
		response := s.syncResponse(ctx, familyID, nil, nil, snapshot.Cursor, false, snapshot)
		response.ResetRequired = true
		return response, nil
	}
	results := make([]CommandResult, 0, len(request.Commands))
	for index, command := range request.Commands {
		savepoint := fmt.Sprintf("command_%d", index)
		if _, err := tx.ExecContext(ctx, "SAVEPOINT "+savepoint); err != nil {
			return SyncResponse{}, fmt.Errorf("create command savepoint: %w", err)
		}
		_, priorErr := q.CommandResult(ctx, storedb.CommandResultParams{ID: command.ID, FamilyID: familyID})
		isNewCommand := errors.Is(priorErr, sql.ErrNoRows)
		if priorErr != nil && !isNewCommand {
			return SyncResponse{}, fmt.Errorf("read command before apply: %w", priorErr)
		}
		result, commandErr := s.applyCommand(ctx, tx, familyID, userID, request.DeviceID, command)
		if commandErr == nil && isNewCommand && result.Status == "accepted" && command.Kind != "startSleep" && command.Kind != "endSleep" {
			payload, encodeErr := json.Marshal(familyDelivery{OriginDeviceID: request.DeviceID})
			if encodeErr != nil {
				commandErr = encodeErr
			} else {
				commandErr = queueDelivery(ctx, q, familyID, "familyChanged", payload, s.now().UTC())
			}
		}
		if commandErr != nil {
			if _, err := tx.ExecContext(ctx, "ROLLBACK TO "+savepoint); err != nil {
				return SyncResponse{}, fmt.Errorf("rollback command: %w", err)
			}
			result = CommandResult{ID: command.ID, Status: "rejected", Error: commandErr.Error()}
			result.EntityID, result.Payload = currentCommandEntity(ctx, tx, familyID, command)
		}
		if _, err := tx.ExecContext(ctx, "RELEASE "+savepoint); err != nil {
			return SyncResponse{}, fmt.Errorf("release command savepoint: %w", err)
		}
		encoded, err := json.Marshal(result)
		if err != nil {
			return SyncResponse{}, fmt.Errorf("encode command result: %w", err)
		}
		if err := q.RecordCommand(ctx, storedb.RecordCommandParams{ID: command.ID, FamilyID: familyID, UserID: userID, Kind: command.Kind, ResultJson: encoded, CreatedAt: formatTime(s.now().UTC())}); err != nil {
			return SyncResponse{}, fmt.Errorf("record command: %w", err)
		}
		results = append(results, result)
	}
	compacted, err := s.maybeCompactSyncHistory(ctx, tx, familyID)
	if err != nil {
		return SyncResponse{}, err
	}
	baseCursor := request.Cursor
	snapshot := compacted
	if snapshot == nil {
		stored, snapshotErr := q.FamilySyncSnapshot(ctx, familyID)
		if snapshotErr == nil && stored.Generation == s.store.SyncGeneration && request.Cursor < stored.Cursor {
			snapshot, err = s.currentSnapshot(ctx, tx, familyID)
			if err != nil {
				return SyncResponse{}, err
			}
		} else if snapshotErr != nil && !errors.Is(snapshotErr, sql.ErrNoRows) {
			return SyncResponse{}, fmt.Errorf("read compaction snapshot: %w", snapshotErr)
		}
	}
	if snapshot != nil {
		baseCursor = snapshot.Cursor
	}
	events, hasMore, nextCursor, err := readEvents(ctx, q, familyID, baseCursor, request.Limit)
	if err != nil {
		return SyncResponse{}, err
	}
	if err := tx.Commit(); err != nil {
		return SyncResponse{}, err
	}
	if nextCursor > request.Cursor {
		s.broker.publish(familyID, nextCursor)
	}
	s.pruneSentDeliveries(ctx, s.store.Queries)
	return s.syncResponse(ctx, familyID, results, events, nextCursor, hasMore, snapshot), nil
}

func (s *Server) syncResponse(ctx context.Context, familyID string, results []CommandResult, events []Event, nextCursor int64, hasMore bool, snapshot *FamilySnapshot) SyncResponse {
	response := SyncResponse{
		CommandResults: results, Events: events, NextCursor: nextCursor, HasMore: hasMore, ServerTime: s.now().UTC(), Generation: s.store.SyncGeneration, Snapshot: snapshot,
		SleepForecast: s.sleepForecast(ctx, familyID),
	}
	if response.SleepForecast != nil {
		response.NextSleepEstimate = response.SleepForecast.NextSleepEstimate
	}
	return response
}

func currentCommandEntity(ctx context.Context, tx *sql.Tx, familyID string, command Command) (string, json.RawMessage) {
	var identity struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(command.Payload, &identity) != nil || identity.ID == "" {
		return "", nil
	}
	switch command.Kind {
	case "createChild", "updateChild", "updatePredictionSettings":
		payload, _, err := childJSON(ctx, tx, familyID, identity.ID)
		if err == nil {
			return identity.ID, payload
		}
	case "startSleep", "endSleep", "upsertSleep", "deleteSleep":
		payload, _, err := sleepJSON(ctx, tx, familyID, identity.ID)
		if err == nil {
			return identity.ID, payload
		}
	}
	return identity.ID, nil
}

func (s *Server) applyCommand(ctx context.Context, tx *sql.Tx, familyID, userID, deviceID string, command Command) (CommandResult, error) {
	if command.ID == "" || command.Kind == "" {
		return CommandResult{ID: command.ID}, errors.New("command id and payload are required")
	}
	q := s.store.Queries.WithTx(tx)
	prior, err := q.CommandResult(ctx, storedb.CommandResultParams{ID: command.ID, FamilyID: familyID})
	if err == nil {
		var result CommandResult
		if json.Unmarshal(prior, &result) != nil {
			return CommandResult{}, errors.New("invalid stored command")
		}
		return result, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CommandResult{}, err
	}
	switch command.Kind {
	case "createChild":
		return s.createChild(ctx, tx, familyID, command)
	case "updateChild", "updatePredictionSettings":
		return s.updateChild(ctx, tx, familyID, command)
	case "startSleep":
		return s.startSleep(ctx, tx, familyID, userID, deviceID, command)
	case "endSleep":
		return s.endSleep(ctx, tx, familyID, deviceID, command)
	case "upsertSleep":
		return s.upsertSleep(ctx, tx, familyID, userID, command)
	case "deleteSleep":
		return s.deleteSleep(ctx, tx, familyID, command)
	default:
		return CommandResult{ID: command.ID}, fmt.Errorf("unsupported command %q", command.Kind)
	}
}

func (s *Server) createChild(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload childPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" || payload.Nickname == "" || payload.BirthDate == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid child")
	}
	if payload.PredictionMode == "" {
		payload.PredictionMode = "adaptive"
	}
	if payload.QuietHoursStartMinutes == 0 {
		payload.QuietHoursStartMinutes = 1200
	}
	if payload.QuietHoursEndMinutes == 0 {
		payload.QuietHoursEndMinutes = 360
	}
	if payload.TimeZone == "" {
		payload.TimeZone = "Europe/Helsinki"
	}
	if _, err := time.LoadLocation(payload.TimeZone); err != nil {
		return CommandResult{ID: command.ID}, errors.New("invalid timezone")
	}
	now := formatTime(s.now().UTC())
	q := s.store.Queries.WithTx(tx)
	err := q.CreateChild(ctx, storedb.CreateChildParams{ID: payload.ID, FamilyID: familyID, Nickname: payload.Nickname, BirthDate: payload.BirthDate, PredictionMode: payload.PredictionMode, ManualIntervalMinutes: nullableInt(payload.ManualIntervalMinutes), QuietHoursStartMinutes: int64(payload.QuietHoursStartMinutes), QuietHoursEndMinutes: int64(payload.QuietHoursEndMinutes), TimeZone: payload.TimeZone, UpdatedAt: now})
	if err != nil {
		return CommandResult{ID: command.ID}, fmt.Errorf("create child: %w", err)
	}
	encoded, revision, err := childJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "child", payload.ID, "upsert", revision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) updateChild(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload childPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid child")
	}
	q := s.store.Queries.WithTx(tx)
	revision64, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	if command.ExpectedRevision != nil && *command.ExpectedRevision != int(revision64) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	if payload.PredictionMode == "" {
		payload.PredictionMode = "adaptive"
	}
	if payload.TimeZone != "" {
		if _, err := time.LoadLocation(payload.TimeZone); err != nil {
			return CommandResult{ID: command.ID}, errors.New("invalid timezone")
		}
	}
	now := formatTime(s.now().UTC())
	err = q.UpdateChild(ctx, storedb.UpdateChildParams{Nickname: payload.Nickname, BirthDate: payload.BirthDate, PredictionMode: payload.PredictionMode, ManualIntervalMinutes: nullableInt(payload.ManualIntervalMinutes), QuietHoursStartMinutes: int64(payload.QuietHoursStartMinutes), QuietHoursEndMinutes: int64(payload.QuietHoursEndMinutes), TimeZone: payload.TimeZone, UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, revision, err := childJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "child", payload.ID, "upsert", revision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) startSleep(ctx context.Context, tx *sql.Tx, familyID, userID, deviceID string, command Command) (CommandResult, error) {
	var payload sleepPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" || payload.ChildID == "" || payload.StartedAt.IsZero() {
		return CommandResult{ID: command.ID}, errors.New("invalid sleep")
	}
	if payload.Source == "" {
		payload.Source = "phone"
	}
	normalizeSleepContext(&payload)
	q := s.store.Queries.WithTx(tx)
	if _, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ChildID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	activeID, err := q.ActiveSleepForChild(ctx, storedb.ActiveSleepForChildParams{FamilyID: familyID, ChildID: payload.ChildID})
	if err == nil {
		encoded, _, readErr := sleepJSON(ctx, tx, familyID, activeID)
		return CommandResult{ID: command.ID, Status: "accepted", EntityID: activeID, Payload: encoded}, readErr
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CommandResult{ID: command.ID}, err
	}
	now := formatTime(s.now().UTC())
	err = q.CreateActiveSleep(ctx, storedb.CreateActiveSleepParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, StartedAt: formatTime(payload.StartedAt), AuthorID: userID, Source: payload.Source, StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, revision, err := sleepJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "sleepSession", payload.ID, "upsert", revision, encoded, now)
	}
	if err == nil {
		err = queueActivityDelivery(ctx, q, familyID, "activityStart", deviceID, encoded, s.now().UTC())
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) endSleep(ctx context.Context, tx *sql.Tx, familyID, deviceID string, command Command) (CommandResult, error) {
	var payload sleepPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.EndedAt == nil {
		return CommandResult{ID: command.ID}, errors.New("end time required")
	}
	q := s.store.Queries.WithTx(tx)
	normalizeSleepContext(&payload)
	var id, started string
	var revision int64
	if payload.ID == "" {
		active, err := q.ActiveSleepForFamily(ctx, familyID)
		if err != nil {
			return CommandResult{ID: command.ID}, errors.New("active sleep not found")
		}
		id, started, revision = active.ID, active.StartedAt, active.Revision
	} else {
		active, err := q.ActiveSleepByID(ctx, storedb.ActiveSleepByIDParams{FamilyID: familyID, ID: payload.ID})
		if err != nil {
			return CommandResult{ID: command.ID}, errors.New("active sleep not found")
		}
		id, started, revision = active.ID, active.StartedAt, active.Revision
	}
	startedAt, _ := parseTime(started)
	if !payload.EndedAt.After(startedAt) {
		return CommandResult{ID: command.ID}, errors.New("end must be after start")
	}
	if command.ExpectedRevision != nil && *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	now := formatTime(s.now().UTC())
	if err := q.EndSleep(ctx, storedb.EndSleepParams{EndedAt: nullableString(payload.EndedAt), EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now, ID: id, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, currentRevision, err := sleepJSON(ctx, tx, familyID, id)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "sleepSession", id, "upsert", currentRevision, encoded, now)
	}
	if err == nil {
		err = queueActivityDelivery(ctx, q, familyID, "activityEnd", deviceID, encoded, s.now().UTC())
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: id, Payload: encoded}, err
}

func (s *Server) upsertSleep(ctx context.Context, tx *sql.Tx, familyID, userID string, command Command) (CommandResult, error) {
	var payload sleepPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" || payload.ChildID == "" || payload.StartedAt.IsZero() {
		return CommandResult{ID: command.ID}, errors.New("invalid sleep")
	}
	if payload.EndedAt != nil && !payload.EndedAt.After(payload.StartedAt) {
		return CommandResult{ID: command.ID}, errors.New("end must be after start")
	}
	normalizeSleepContext(&payload)
	q := s.store.Queries.WithTx(tx)
	if _, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ChildID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	revision, err := q.SleepRevision(ctx, storedb.SleepRevisionParams{ID: payload.ID, FamilyID: familyID})
	now := formatTime(s.now().UTC())
	if errors.Is(err, sql.ErrNoRows) {
		if payload.Source == "" {
			payload.Source = "manual"
		}
		err = q.CreateSleep(ctx, storedb.CreateSleepParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, StartedAt: formatTime(payload.StartedAt), EndedAt: nullableString(payload.EndedAt), AuthorID: userID, Source: payload.Source, StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now})
	} else if err == nil {
		if command.ExpectedRevision != nil && *command.ExpectedRevision != int(revision) {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.UpdateSleep(ctx, storedb.UpdateSleepParams{StartedAt: formatTime(payload.StartedAt), EndedAt: nullableString(payload.EndedAt), StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	}
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := s.mergeOverlaps(ctx, tx, familyID, payload.ChildID); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, currentRevision, err := sleepJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "sleepSession", payload.ID, "upsert", currentRevision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) deleteSleep(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid sleep id")
	}
	q := s.store.Queries.WithTx(tx)
	revision, err := q.ExistingSleepRevision(ctx, storedb.ExistingSleepRevisionParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("sleep not found")
	}
	if command.ExpectedRevision != nil && *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	now := formatTime(s.now().UTC())
	revision++
	if err := q.DeleteSleep(ctx, storedb.DeleteSleepParams{DeletedAt: nullString(now), Revision: revision, UpdatedAt: now, ID: payload.ID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded := json.RawMessage(`{"id":"` + payload.ID + `"}`)
	if err := appendEvent(ctx, q, familyID, "sleepSession", payload.ID, "delete", int(revision), encoded, now); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, nil
}

func (s *Server) mergeOverlaps(ctx context.Context, tx *sql.Tx, familyID, childID string) error {
	q := s.store.Queries.WithTx(tx)
	rows, err := q.SleepIntervals(ctx, storedb.SleepIntervalsParams{FamilyID: familyID, ChildID: childID})
	if err != nil {
		return err
	}
	type interval struct {
		id    string
		start time.Time
		end   *time.Time
	}
	values := make([]interval, 0, len(rows))
	for _, row := range rows {
		value := interval{id: row.ID}
		value.start, _ = parseTime(row.StartedAt)
		if row.EndedAt.Valid {
			parsed, _ := parseTime(row.EndedAt.String)
			value.end = &parsed
		}
		values = append(values, value)
	}
	for index := 1; index < len(values); index++ {
		left, right := values[index-1], values[index]
		near := right.start.Sub(left.start) <= 2*time.Minute
		overlap := left.end == nil || !right.start.After(*left.end)
		if !near && !overlap {
			continue
		}
		canonical, duplicate := left, right
		if right.start.Before(left.start) || (right.start.Equal(left.start) && right.id < left.id) {
			canonical, duplicate = right, left
		}
		mergedStart := canonical.start
		if duplicate.start.Before(mergedStart) {
			mergedStart = duplicate.start
		}
		mergedEnd := canonical.end
		if mergedEnd != nil && (duplicate.end == nil || duplicate.end.After(*mergedEnd)) {
			mergedEnd = duplicate.end
		}
		now := formatTime(s.now().UTC())
		if err := q.MergeSleep(ctx, storedb.MergeSleepParams{StartedAt: formatTime(mergedStart), EndedAt: nullableString(mergedEnd), UpdatedAt: now, ID: canonical.id}); err != nil {
			return err
		}
		if err := q.SupersedeSleep(ctx, storedb.SupersedeSleepParams{SupersededByID: nullString(canonical.id), UpdatedAt: now, ID: duplicate.id}); err != nil {
			return err
		}
		canonicalJSON, canonicalRevision, err := sleepJSON(ctx, tx, familyID, canonical.id)
		if err != nil {
			return err
		}
		if err := appendEvent(ctx, q, familyID, "sleepSession", canonical.id, "upsert", canonicalRevision, canonicalJSON, now); err != nil {
			return err
		}
		duplicateJSON, duplicateRevision, err := sleepJSON(ctx, tx, familyID, duplicate.id)
		if err != nil {
			return err
		}
		if err := appendEvent(ctx, q, familyID, "sleepSession", duplicate.id, "upsert", duplicateRevision, duplicateJSON, now); err != nil {
			return err
		}
	}
	return nil
}

func childJSON(ctx context.Context, tx *sql.Tx, familyID, id string) (json.RawMessage, int, error) {
	row, err := storedb.New(tx).ChildRecord(ctx, storedb.ChildRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return nil, 0, err
	}
	value := map[string]any{"id": row.ID, "familyID": row.FamilyID, "nickname": row.Nickname, "birthDate": row.BirthDate, "predictionMode": row.PredictionMode, "quietHoursStartMinutes": row.QuietHoursStartMinutes, "quietHoursEndMinutes": row.QuietHoursEndMinutes, "timeZone": row.TimeZone, "revision": row.Revision, "updatedAt": row.UpdatedAt}
	if row.ManualIntervalMinutes.Valid {
		value["manualIntervalMinutes"] = row.ManualIntervalMinutes.Int64
	}
	encoded, err := json.Marshal(value)
	return encoded, int(row.Revision), err
}

func sleepJSON(ctx context.Context, tx *sql.Tx, familyID, id string) (json.RawMessage, int, error) {
	row, err := storedb.New(tx).SleepRecord(ctx, storedb.SleepRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return nil, 0, err
	}
	value := sleepRecord{ID: row.ID, FamilyID: row.FamilyID, ChildID: row.ChildID, Revision: int(row.Revision), AuthorID: row.AuthorID, Source: row.Source, StartCondition: row.StartCondition, SleepLocation: row.SleepLocation, EndCondition: row.EndCondition, WakeMood: row.WakeMood, WakeReason: row.WakeReason}
	if row.CaregiverIntervened.Valid {
		item := row.CaregiverIntervened.Int64 != 0
		value.CaregiverIntervened = &item
	}
	value.StartedAt, _ = parseTime(row.StartedAt)
	value.UpdatedAt, _ = parseTime(row.UpdatedAt)
	if row.EndedAt.Valid {
		parsed, _ := parseTime(row.EndedAt.String)
		value.EndedAt = &parsed
	}
	if row.SupersededByID.Valid {
		value.SupersededByID = &row.SupersededByID.String
	}
	if row.DeletedAt.Valid {
		parsed, _ := parseTime(row.DeletedAt.String)
		value.DeletedAt = &parsed
	}
	encoded, err := json.Marshal(value)
	return encoded, value.Revision, err
}

func appendEvent(ctx context.Context, q *storedb.Queries, familyID, entityType, entityID, operation string, revision int, payload []byte, createdAt string) error {
	return q.AppendEvent(ctx, storedb.AppendEventParams{FamilyID: familyID, EntityType: entityType, EntityID: entityID, Operation: operation, Revision: int64(revision), PayloadJson: payload, CreatedAt: createdAt})
}

func queueDelivery(ctx context.Context, q *storedb.Queries, familyID, kind string, payload []byte, due time.Time) error {
	return q.QueueDelivery(ctx, storedb.QueueDeliveryParams{ID: newID(), FamilyID: familyID, Kind: kind, PayloadJson: payload, DueAt: formatTime(due), CreatedAt: formatTime(time.Now().UTC())})
}

func queueActivityDelivery(ctx context.Context, q *storedb.Queries, familyID, kind, originDeviceID string, sleepJSON []byte, due time.Time) error {
	var sleep sleepRecord
	if err := json.Unmarshal(sleepJSON, &sleep); err != nil {
		return err
	}
	payload, err := json.Marshal(activityDelivery{OriginDeviceID: originDeviceID, Sleep: sleep})
	if err != nil {
		return err
	}
	return queueDelivery(ctx, q, familyID, kind, payload, due)
}

func readEvents(ctx context.Context, q *storedb.Queries, familyID string, cursor int64, limit int) ([]Event, bool, int64, error) {
	rows, err := q.ReadEvents(ctx, storedb.ReadEventsParams{FamilyID: familyID, Cursor: cursor, ResultLimit: int64(limit + 1)})
	if err != nil {
		return nil, false, cursor, err
	}
	events := make([]Event, 0, min(limit, len(rows)))
	for _, row := range rows {
		created, _ := parseTime(row.CreatedAt)
		events = append(events, Event{Cursor: row.Cursor, EntityType: row.EntityType, EntityID: row.EntityID, Operation: row.Operation, Revision: int(row.Revision), Payload: row.PayloadJson, CreatedAt: created})
	}
	hasMore := len(events) > limit
	if hasMore {
		events = events[:limit]
	}
	next := cursor
	if len(events) > 0 {
		next = events[len(events)-1].Cursor
	}
	return events, hasMore, next, nil
}

func (s *Server) sleepForecast(ctx context.Context, familyID string) *SleepForecast {
	child, err := s.store.Queries.PredictionChild(ctx, familyID)
	if err != nil {
		return nil
	}
	rows, err := s.store.Queries.SweetSpotHistory(ctx, child.ID)
	if err != nil {
		return nil
	}
	sessions := make([]sweetspot.Session, 0, len(rows))
	for _, row := range rows {
		if !row.EndedAt.Valid {
			continue
		}
		started, startErr := parseTime(row.StartedAt)
		ended, endErr := parseTime(row.EndedAt.String)
		if startErr == nil && endErr == nil {
			item := sweetspot.Session{StartedAt: started, EndedAt: ended, StartCondition: row.StartCondition, SleepLocation: row.SleepLocation, EndCondition: row.EndCondition, WakeMood: row.WakeMood, WakeReason: row.WakeReason}
			if row.CaregiverIntervened.Valid {
				value := row.CaregiverIntervened.Int64 != 0
				item.CaregiverIntervened = &value
			}
			sessions = append(sessions, item)
		}
	}
	birth, err := time.Parse("2006-01-02", child.BirthDate)
	if err != nil {
		return nil
	}
	var manualMinutes *int
	if child.PredictionMode == "manual" && child.ManualIntervalMinutes.Valid {
		value := int(child.ManualIntervalMinutes.Int64)
		manualMinutes = &value
	}
	location, err := time.LoadLocation(child.TimeZone)
	if err != nil {
		return nil
	}
	forecast := &SleepForecast{ChildID: child.ID}
	activeID, activeErr := s.store.Queries.ActiveSleepForChild(ctx, storedb.ActiveSleepForChildParams{FamilyID: familyID, ChildID: child.ID})
	if activeErr == nil {
		row, readErr := s.store.Queries.SleepRecord(ctx, storedb.SleepRecordParams{ID: activeID, FamilyID: familyID})
		if readErr != nil {
			return nil
		}
		startedAt, parseErr := parseTime(row.StartedAt)
		if parseErr != nil {
			return nil
		}
		active := sweetspot.Session{StartedAt: startedAt, StartCondition: row.StartCondition, SleepLocation: row.SleepLocation}
		wake, ok := sweetspot.PredictWake(active, s.now().UTC(), location, sessions)
		if !ok {
			return forecast
		}
		wakePrediction := predictionFromEstimate(wake)
		forecast.ActiveSleepID = &activeID
		forecast.WakeEstimate = &wakePrediction
		forecast.NextSleepIsProvisional = true
		predictedSession := active
		predictedSession.EndedAt = wake.Target
		if next, ok := sweetspot.Predict(sweetspot.Request{WokeAt: wake.Target, BirthDate: birth, Location: location, History: sessions, Current: &predictedSession, ManualMinutes: manualMinutes}); ok {
			value := predictionFromEstimate(next)
			forecast.NextSleepEstimate = &value
		}
		return forecast
	}
	if !errors.Is(activeErr, sql.ErrNoRows) {
		return nil
	}
	if len(sessions) == 0 {
		return forecast
	}
	latest := sessions[len(sessions)-1]
	estimate, ok := sweetspot.Predict(sweetspot.Request{WokeAt: latest.EndedAt, BirthDate: birth, Location: location, History: sessions, Current: &latest, ManualMinutes: manualMinutes})
	if !ok {
		return forecast
	}
	value := predictionFromEstimate(estimate)
	forecast.NextSleepEstimate = &value
	return forecast
}

func (s *Server) nextPrediction(ctx context.Context, familyID string) *Prediction {
	forecast := s.sleepForecast(ctx, familyID)
	if forecast == nil {
		return nil
	}
	return forecast.NextSleepEstimate
}

func predictionFromEstimate(estimate sweetspot.Estimate) Prediction {
	return Prediction{TargetAt: estimate.Target, RangeStartAt: estimate.RangeStart, RangeEndAt: estimate.RangeEnd, Confidence: estimate.Confidence, Explanation: estimate.Explanation, AlgorithmVersion: sweetspot.AlgorithmVersion, Kind: estimate.Kind, SampleCount: estimate.SampleCount}
}

func normalizeSleepContext(payload *sleepPayload) {
	if payload.WakeMood == "" {
		payload.WakeMood = "unknown"
	}
	if payload.WakeReason == "" {
		payload.WakeReason = "unknown"
	}
	validMood := payload.WakeMood == "unknown" || payload.WakeMood == "calm" || payload.WakeMood == "fussy" || payload.WakeMood == "crying"
	validReason := payload.WakeReason == "unknown" || payload.WakeReason == "natural" || payload.WakeReason == "feed" || payload.WakeReason == "discomfort" || payload.WakeReason == "caregiver"
	if !validMood {
		payload.WakeMood = "unknown"
	}
	if !validReason {
		payload.WakeReason = "unknown"
	}
}
