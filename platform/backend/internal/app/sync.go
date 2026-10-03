package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
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
	GrowthReference        string `json:"growthReference,omitempty"`
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

type growthMeasurementPayload struct {
	ID                string    `json:"id"`
	ChildID           string    `json:"childID"`
	MeasuredAt        time.Time `json:"measuredAt"`
	WeightGrams       *int      `json:"weightGrams,omitempty"`
	HeightMillimeters *int      `json:"heightMillimeters,omitempty"`
	Note              string    `json:"note,omitempty"`
}

type growthMeasurementRecord struct {
	ID                string     `json:"id"`
	FamilyID          string     `json:"familyID"`
	ChildID           string     `json:"childID"`
	MeasuredAt        time.Time  `json:"measuredAt"`
	WeightGrams       *int       `json:"weightGrams,omitempty"`
	HeightMillimeters *int       `json:"heightMillimeters,omitempty"`
	Note              string     `json:"note,omitempty"`
	Revision          int        `json:"revision"`
	UpdatedAt         time.Time  `json:"updatedAt"`
	DeletedAt         *time.Time `json:"deletedAt,omitempty"`
}

type temperatureReadingPayload struct {
	ID           string    `json:"id"`
	ChildID      string    `json:"childID"`
	MeasuredAt   time.Time `json:"measuredAt"`
	CentiCelsius int       `json:"centiCelsius"`
	Note         string    `json:"note,omitempty"`
}

type temperatureReadingRecord struct {
	ID           string     `json:"id"`
	FamilyID     string     `json:"familyID"`
	ChildID      string     `json:"childID"`
	MeasuredAt   time.Time  `json:"measuredAt"`
	CentiCelsius int        `json:"centiCelsius"`
	Note         string     `json:"note"`
	Revision     int        `json:"revision"`
	UpdatedAt    time.Time  `json:"updatedAt"`
	DeletedAt    *time.Time `json:"deletedAt,omitempty"`
}

type activityDelivery struct {
	TargetDeviceID string      `json:"targetDeviceID,omitempty"`
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
	committedCursor, err := q.LatestFamilyCursor(ctx, familyID)
	if err != nil {
		return SyncResponse{}, fmt.Errorf("read committed family cursor: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return SyncResponse{}, err
	}
	// Announce the family's newest cursor, not this caller's page boundary: a
	// paginated caller can be far behind watchers that are already past it.
	if committedCursor > latestCursor {
		s.broker.publish(familyID, committedCursor)
	}
	s.pruneSentDeliveries(ctx, s.store.Queries)
	response := s.syncResponse(ctx, familyID, results, events, nextCursor, hasMore, snapshot)
	cutoff := response.ServerTime.Add(-s.journalRetention)
	response.JournalCutoff = &cutoff
	return response, nil
}

func (s *Server) syncResponse(ctx context.Context, familyID string, results []CommandResult, events []Event, nextCursor int64, hasMore bool, snapshot *FamilySnapshot) SyncResponse {
	response := SyncResponse{
		CommandResults: results, Events: events, NextCursor: nextCursor, HasMore: hasMore, ServerTime: s.now().UTC(), Generation: s.store.SyncGeneration, Snapshot: snapshot,
	}
	// A client keeps only the last page's forecast and reference data, so
	// intermediate pages of a catch-up skip both.
	if hasMore {
		return response
	}
	response.SleepForecast = s.sleepForecast(ctx, familyID)
	if response.SleepForecast != nil {
		response.NextSleepEstimate = response.SleepForecast.NextSleepEstimate
	}
	if rows, err := s.store.Queries.GrowthReferencePoints(ctx); err == nil {
		response.GrowthReferencePoints = make([]GrowthReferencePoint, 0, len(rows))
		for _, row := range rows {
			response.GrowthReferencePoints = append(response.GrowthReferencePoints, GrowthReferencePoint{
				Reference: row.Reference, Metric: row.Metric, AgeMonths: int(row.AgeMonths), SD: int(row.Sd), Value: int(row.Value),
			})
		}
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
	case "createChild", "updateChild", "deleteChild":
		payload, _, err := childJSON(ctx, tx, familyID, identity.ID)
		if err == nil {
			return identity.ID, payload
		}
	case "startSleep", "endSleep", "upsertSleep", "deleteSleep":
		payload, _, err := sleepJSON(ctx, tx, familyID, identity.ID)
		if err == nil {
			return identity.ID, payload
		}
	case "upsertGrowthMeasurement", "deleteGrowthMeasurement":
		payload, _, err := growthMeasurementJSON(ctx, tx, familyID, identity.ID)
		if err == nil {
			return identity.ID, payload
		}
	case "upsertTemperatureReading", "deleteTemperatureReading":
		payload, _, err := temperatureReadingJSON(ctx, tx, familyID, identity.ID)
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
		if result.Status != "accepted" {
			// The decision stays stored, but the entity it names may exist now (for
			// example after another device's replay into a restored database). Send
			// it as a fresh rejection would, so the client rebases instead of
			// waiting for a target that is already there.
			if entityID, payload := currentCommandEntity(ctx, tx, familyID, command); payload != nil {
				result.EntityID, result.Payload = entityID, payload
			}
		}
		return result, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CommandResult{}, err
	}
	switch command.Kind {
	case "createChild":
		return s.createChild(ctx, tx, familyID, command)
	case "updateChild":
		return s.updateChild(ctx, tx, familyID, command)
	case "deleteChild":
		return s.deleteChild(ctx, tx, familyID, command)
	case "startSleep":
		return s.startSleep(ctx, tx, familyID, userID, deviceID, command)
	case "endSleep":
		return s.endSleep(ctx, tx, familyID, deviceID, command)
	case "upsertSleep":
		return s.upsertSleep(ctx, tx, familyID, userID, command)
	case "deleteSleep":
		return s.deleteSleep(ctx, tx, familyID, command)
	case "upsertGrowthMeasurement":
		return s.upsertGrowthMeasurement(ctx, tx, familyID, command)
	case "deleteGrowthMeasurement":
		return s.deleteGrowthMeasurement(ctx, tx, familyID, command)
	case "upsertTemperatureReading":
		return s.upsertTemperatureReading(ctx, tx, familyID, command)
	case "deleteTemperatureReading":
		return s.deleteTemperatureReading(ctx, tx, familyID, command)
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
	if payload.GrowthReference == "" {
		payload.GrowthReference = "none"
	}
	if !validGrowthReference(payload.GrowthReference) {
		return CommandResult{ID: command.ID}, errors.New("invalid growth reference")
	}
	if _, err := time.LoadLocation(payload.TimeZone); err != nil {
		return CommandResult{ID: command.ID}, errors.New("invalid timezone")
	}
	now := formatTime(s.now().UTC())
	q := s.store.Queries.WithTx(tx)
	err := q.CreateChild(ctx, storedb.CreateChildParams{ID: payload.ID, FamilyID: familyID, Nickname: payload.Nickname, BirthDate: payload.BirthDate, PredictionMode: payload.PredictionMode, ManualIntervalMinutes: nullableInt(payload.ManualIntervalMinutes), QuietHoursStartMinutes: int64(payload.QuietHoursStartMinutes), QuietHoursEndMinutes: int64(payload.QuietHoursEndMinutes), TimeZone: payload.TimeZone, GrowthReference: payload.GrowthReference, UpdatedAt: now})
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
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(revision64) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	if payload.PredictionMode == "" {
		payload.PredictionMode = "adaptive"
	}
	if payload.GrowthReference != "" && !validGrowthReference(payload.GrowthReference) {
		return CommandResult{ID: command.ID}, errors.New("invalid growth reference")
	}
	if payload.TimeZone != "" {
		if _, err := time.LoadLocation(payload.TimeZone); err != nil {
			return CommandResult{ID: command.ID}, errors.New("invalid timezone")
		}
	}
	now := formatTime(s.now().UTC())
	err = q.UpdateChild(ctx, storedb.UpdateChildParams{Nickname: payload.Nickname, BirthDate: payload.BirthDate, PredictionMode: payload.PredictionMode, ManualIntervalMinutes: nullableInt(payload.ManualIntervalMinutes), QuietHoursStartMinutes: int64(payload.QuietHoursStartMinutes), QuietHoursEndMinutes: int64(payload.QuietHoursEndMinutes), TimeZone: payload.TimeZone, GrowthReference: payload.GrowthReference, UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, revision, err := childJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "child", payload.ID, "upsert", revision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) deleteChild(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid child")
	}
	q := s.store.Queries.WithTx(tx)
	revision, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	if _, activeErr := q.ActiveSleepForChild(ctx, storedb.ActiveSleepForChildParams{FamilyID: familyID, ChildID: payload.ID}); activeErr == nil {
		return CommandResult{ID: command.ID}, errors.New("end the active sleep before deleting the child")
	} else if !errors.Is(activeErr, sql.ErrNoRows) {
		return CommandResult{ID: command.ID}, activeErr
	}
	now := formatTime(s.now().UTC())
	rows, err := q.DeleteChild(ctx, storedb.DeleteChildParams{DeletedAt: sql.NullString{String: now, Valid: true}, UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if rows != 1 {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	encoded, newRevision, err := childJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "child", payload.ID, "delete", newRevision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

// duplicateStartWindow bounds how far apart two starts of the same sleep can be.
const duplicateStartWindow = 15 * time.Minute

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
	now := formatTime(s.now().UTC())
	duplicate, err := q.DuplicateStartCandidate(ctx, storedb.DuplicateStartCandidateParams{
		FamilyID: familyID, ChildID: payload.ChildID, StartedAt: formatTime(payload.StartedAt),
		WindowStart: formatTime(payload.StartedAt.Add(-duplicateStartWindow)), WindowEnd: formatTime(payload.StartedAt.Add(duplicateStartWindow)),
	})
	if err == nil {
		// Two caregivers tapping start for the same sleep share one session. Map
		// onto the entry the diary presents, so the alias names a visible session.
		encoded, _, readErr := sleepJSON(ctx, tx, familyID, duplicate.PresentedID)
		return CommandResult{ID: command.ID, Status: "accepted", EntityID: duplicate.PresentedID, Payload: encoded}, readErr
	} else if !errors.Is(err, sql.ErrNoRows) {
		return CommandResult{ID: command.ID}, err
	}
	// A later start is a new sleep; the presentation shows the active one ended
	// at this start until its own end arrives.
	activeID, err := q.ActiveSleepForChild(ctx, storedb.ActiveSleepForChildParams{FamilyID: familyID, ChildID: payload.ChildID})
	if errors.Is(err, sql.ErrNoRows) {
		activeID = ""
	} else if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	err = q.CreateActiveSleep(ctx, storedb.CreateActiveSleepParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, StartedAt: formatTime(payload.StartedAt), AuthorID: userID, Source: payload.Source, StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := s.presentSleeps(ctx, tx, familyID, payload.ChildID, payload.ID); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if activeID != "" {
		previous, readErr := q.SleepRecord(ctx, storedb.SleepRecordParams{ID: activeID, FamilyID: familyID})
		if readErr != nil {
			return CommandResult{ID: command.ID}, readErr
		}
		if previous.EndedAt.Valid {
			ended, _, err := sleepJSON(ctx, tx, familyID, activeID)
			if err == nil {
				err = queueActivityDelivery(ctx, q, familyID, "activityEnd", deviceID, ended, s.now().UTC())
			}
			if err != nil {
				return CommandResult{ID: command.ID}, err
			}
		}
	}
	encoded, _, err := sleepJSON(ctx, tx, familyID, payload.ID)
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
	id := payload.ID
	if id == "" {
		active, err := q.ActiveSleepForFamily(ctx, familyID)
		if err != nil {
			return CommandResult{ID: command.ID}, errors.New("active sleep not found")
		}
		id = active.ID
	}
	// The recorded sleep, not its presentation: a later sleep may already show
	// it ended, or a merge may fold it into another session, and its own end
	// still belongs to it.
	active, err := q.RecordedActiveSleep(ctx, storedb.RecordedActiveSleepParams{FamilyID: familyID, ID: id})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("active sleep not found")
	}
	startedAt, _ := parseTime(active.RecordedStartedAt)
	if !payload.EndedAt.After(startedAt) {
		return CommandResult{ID: command.ID}, errors.New("end must be after start")
	}
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(active.Revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	now := formatTime(s.now().UTC())
	if err := q.EndSleep(ctx, storedb.EndSleepParams{EndedAt: nullableString(payload.EndedAt), EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now, ID: id, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	record, err := q.SleepRecord(ctx, storedb.SleepRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	// A timer started offline can cover a sleep another caregiver logged by hand.
	if err := s.presentSleeps(ctx, tx, familyID, record.ChildID, id); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, _, err := sleepJSON(ctx, tx, familyID, id)
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
	current, err := q.SleepRecord(ctx, storedb.SleepRecordParams{ID: payload.ID, FamilyID: familyID})
	now := formatTime(s.now().UTC())
	if errors.Is(err, sql.ErrNoRows) {
		if command.ExpectedRevision != nil {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		if payload.Source == "" {
			payload.Source = "manual"
		}
		err = q.CreateSleep(ctx, storedb.CreateSleepParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, StartedAt: formatTime(payload.StartedAt), EndedAt: nullableString(payload.EndedAt), AuthorID: userID, Source: payload.Source, StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now})
	} else if err == nil {
		// A tombstoned or superseded row is hidden everywhere, and moving a
		// session to another child is not an edit this command supports.
		if current.DeletedAt.Valid || current.SupersededByID.Valid || current.ChildID != payload.ChildID || command.ExpectedRevision == nil || *command.ExpectedRevision != int(current.Revision) {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.UpdateSleep(ctx, storedb.UpdateSleepParams{StartedAt: formatTime(payload.StartedAt), EndedAt: nullableString(payload.EndedAt), StartCondition: payload.StartCondition, SleepLocation: payload.SleepLocation, EndCondition: payload.EndCondition, WakeMood: payload.WakeMood, WakeReason: payload.WakeReason, CaregiverIntervened: nullableBool(payload.CaregiverIntervened), UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	}
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := s.presentSleeps(ctx, tx, familyID, payload.ChildID, payload.ID); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, _, err := sleepJSON(ctx, tx, familyID, payload.ID)
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
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	record, err := q.SleepRecord(ctx, storedb.SleepRecordParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	now := formatTime(s.now().UTC())
	if err := q.DeleteSleep(ctx, storedb.DeleteSleepParams{DeletedAt: nullString(now), Revision: revision + 1, UpdatedAt: now, ID: payload.ID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	deleted, deletedRevision, err := sleepJSON(ctx, tx, familyID, payload.ID)
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := appendEvent(ctx, q, familyID, "sleepSession", payload.ID, "delete", deletedRevision, deleted, now); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	// Only the named session goes. Sessions it presented reappear, and one it
	// presented as ending an earlier unfinished sleep no longer ends it.
	if err := s.presentSleeps(ctx, tx, familyID, record.ChildID, ""); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, _, err := sleepJSON(ctx, tx, familyID, payload.ID)
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) upsertGrowthMeasurement(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload growthMeasurementPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" || payload.ChildID == "" || payload.MeasuredAt.IsZero() || !validGrowthMeasurement(payload) {
		return CommandResult{ID: command.ID}, errors.New("invalid growth measurement")
	}
	q := s.store.Queries.WithTx(tx)
	if _, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ChildID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	current, err := q.GrowthMeasurementRecord(ctx, storedb.GrowthMeasurementRecordParams{ID: payload.ID, FamilyID: familyID})
	now := formatTime(s.now().UTC())
	if errors.Is(err, sql.ErrNoRows) {
		if command.ExpectedRevision != nil {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.CreateGrowthMeasurement(ctx, storedb.CreateGrowthMeasurementParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, MeasuredAt: formatTime(payload.MeasuredAt), WeightGrams: nullableInt(payload.WeightGrams), HeightMillimeters: nullableInt(payload.HeightMillimeters), Note: payload.Note, UpdatedAt: now})
	} else if err == nil {
		if current.DeletedAt.Valid || current.ChildID != payload.ChildID || command.ExpectedRevision == nil || *command.ExpectedRevision != int(current.Revision) {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.UpdateGrowthMeasurement(ctx, storedb.UpdateGrowthMeasurementParams{MeasuredAt: formatTime(payload.MeasuredAt), WeightGrams: nullableInt(payload.WeightGrams), HeightMillimeters: nullableInt(payload.HeightMillimeters), Note: payload.Note, UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	}
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, currentRevision, err := growthMeasurementJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "growthMeasurement", payload.ID, "upsert", currentRevision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) deleteGrowthMeasurement(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid growth measurement id")
	}
	q := s.store.Queries.WithTx(tx)
	revision, err := q.ExistingGrowthMeasurementRevision(ctx, storedb.ExistingGrowthMeasurementRevisionParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("growth measurement not found")
	}
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	now := formatTime(s.now().UTC())
	revision++
	if err := q.DeleteGrowthMeasurement(ctx, storedb.DeleteGrowthMeasurementParams{DeletedAt: nullString(now), Revision: revision, UpdatedAt: now, ID: payload.ID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, _, err := growthMeasurementJSON(ctx, tx, familyID, payload.ID)
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := appendEvent(ctx, q, familyID, "growthMeasurement", payload.ID, "delete", int(revision), encoded, now); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, nil
}

func (s *Server) upsertTemperatureReading(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload temperatureReadingPayload
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" || payload.ChildID == "" || payload.MeasuredAt.IsZero() || payload.CentiCelsius < 2000 || payload.CentiCelsius > 5000 {
		return CommandResult{ID: command.ID}, errors.New("invalid temperature reading")
	}
	q := s.store.Queries.WithTx(tx)
	if _, err := q.ChildRevision(ctx, storedb.ChildRevisionParams{ID: payload.ChildID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, errors.New("child not found")
	}
	current, err := q.TemperatureReadingRecord(ctx, storedb.TemperatureReadingRecordParams{ID: payload.ID, FamilyID: familyID})
	now := formatTime(s.now().UTC())
	if errors.Is(err, sql.ErrNoRows) {
		if command.ExpectedRevision != nil {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.CreateTemperatureReading(ctx, storedb.CreateTemperatureReadingParams{ID: payload.ID, FamilyID: familyID, ChildID: payload.ChildID, MeasuredAt: formatTime(payload.MeasuredAt), CentiCelsius: int64(payload.CentiCelsius), Note: payload.Note, UpdatedAt: now})
	} else if err == nil {
		if current.DeletedAt.Valid || current.ChildID != payload.ChildID || command.ExpectedRevision == nil || *command.ExpectedRevision != int(current.Revision) {
			return CommandResult{ID: command.ID}, errors.New("stale revision")
		}
		err = q.UpdateTemperatureReading(ctx, storedb.UpdateTemperatureReadingParams{MeasuredAt: formatTime(payload.MeasuredAt), CentiCelsius: int64(payload.CentiCelsius), Note: payload.Note, UpdatedAt: now, ID: payload.ID, FamilyID: familyID})
	}
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, currentRevision, err := temperatureReadingJSON(ctx, tx, familyID, payload.ID)
	if err == nil {
		err = appendEvent(ctx, q, familyID, "temperatureReading", payload.ID, "upsert", currentRevision, encoded, now)
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, err
}

func (s *Server) deleteTemperatureReading(ctx context.Context, tx *sql.Tx, familyID string, command Command) (CommandResult, error) {
	var payload struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(command.Payload, &payload) != nil || payload.ID == "" {
		return CommandResult{ID: command.ID}, errors.New("invalid temperature reading id")
	}
	q := s.store.Queries.WithTx(tx)
	revision, err := q.ExistingTemperatureReadingRevision(ctx, storedb.ExistingTemperatureReadingRevisionParams{ID: payload.ID, FamilyID: familyID})
	if err != nil {
		return CommandResult{ID: command.ID}, errors.New("temperature reading not found")
	}
	if command.ExpectedRevision == nil || *command.ExpectedRevision != int(revision) {
		return CommandResult{ID: command.ID}, errors.New("stale revision")
	}
	now := formatTime(s.now().UTC())
	revision++
	if err := q.DeleteTemperatureReading(ctx, storedb.DeleteTemperatureReadingParams{DeletedAt: nullString(now), Revision: revision, UpdatedAt: now, ID: payload.ID, FamilyID: familyID}); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	encoded, _, err := temperatureReadingJSON(ctx, tx, familyID, payload.ID)
	if err != nil {
		return CommandResult{ID: command.ID}, err
	}
	if err := appendEvent(ctx, q, familyID, "temperatureReading", payload.ID, "delete", int(revision), encoded, now); err != nil {
		return CommandResult{ID: command.ID}, err
	}
	return CommandResult{ID: command.ID, Status: "accepted", EntityID: payload.ID, Payload: encoded}, nil
}

// presentSleeps derives what the diary shows from every session's recorded
// interval, and writes and announces only rows whose presentation changed
// (plus touched, the row the caller just wrote). Overlapping or near-duplicate
// sessions form a run; the earliest is presented with the run's latest end and
// the others are hidden behind it. An unfinished session is presented as ended
// where a sleep starting well after it begins. Because nothing here edits a
// recorded interval, correcting, deleting, or replaying any session reshapes
// the presentation instead of losing a sleep a merge once absorbed.
func (s *Server) presentSleeps(ctx context.Context, tx *sql.Tx, familyID, childID, touched string) error {
	q := s.store.Queries.WithTx(tx)
	rows, err := q.SleepIntervals(ctx, storedb.SleepIntervalsParams{FamilyID: familyID, ChildID: childID})
	if err != nil {
		return err
	}
	type presentation struct {
		start      time.Time
		end        *time.Time
		supersedes *string
	}
	starts := make([]time.Time, len(rows))
	ends := make([]*time.Time, len(rows))
	for index, row := range rows {
		starts[index], _ = parseTime(row.RecordedStartedAt)
		if row.RecordedEndedAt.Valid {
			parsed, _ := parseTime(row.RecordedEndedAt.String)
			ends[index] = &parsed
		}
	}
	desired := make([]presentation, len(rows))
	for index := 0; index < len(rows); {
		first := index
		merged, presented := ends[index], ends[index]
		previousStart := starts[index]
		group := []int{index}
		next := index + 1
		for ; next < len(rows); next++ {
			if merged == nil && starts[next].After(starts[first].Add(duplicateStartWindow)) {
				derived := starts[next]
				presented = &derived
				break
			}
			near := starts[next].Sub(previousStart) <= 2*time.Minute
			// Touching intervals are separate sleeps.
			overlap := merged == nil || starts[next].Before(*merged)
			if !near && !overlap {
				break
			}
			group = append(group, next)
			previousStart = starts[next]
			if merged != nil && (ends[next] == nil || ends[next].After(*merged)) {
				merged = ends[next]
			}
			presented = merged
		}
		// An unfinished session represents a run that is still running, so the
		// wake a caregiver taps on the presented entry reaches a recorded sleep
		// that can take it. Otherwise the earliest session represents the run.
		canonical := first
		for _, member := range group {
			if ends[member] == nil {
				canonical = member
				break
			}
		}
		canonicalID := rows[canonical].ID
		for _, member := range group {
			if member != canonical {
				desired[member] = presentation{start: starts[member], end: ends[member], supersedes: &canonicalID}
			}
		}
		desired[canonical] = presentation{start: starts[first], end: presented}
		index = next
	}
	now := formatTime(s.now().UTC())
	for index, row := range rows {
		want := desired[index]
		wantEnd := nullableString(want.end)
		wantSuperseded := sql.NullString{}
		if want.supersedes != nil {
			wantSuperseded = nullString(*want.supersedes)
		}
		changed := row.StartedAt != formatTime(want.start) || row.EndedAt != wantEnd || row.SupersededByID != wantSuperseded
		if changed {
			if err := q.PresentSleep(ctx, storedb.PresentSleepParams{StartedAt: formatTime(want.start), EndedAt: wantEnd, SupersededByID: wantSuperseded, UpdatedAt: now, ID: row.ID, FamilyID: familyID}); err != nil {
				return err
			}
		}
		if changed || row.ID == touched {
			encoded, revision, err := sleepJSON(ctx, tx, familyID, row.ID)
			if err != nil {
				return err
			}
			if err := appendEvent(ctx, q, familyID, "sleepSession", row.ID, "upsert", revision, encoded, now); err != nil {
				return err
			}
		}
	}
	return nil
}

func childJSON(ctx context.Context, tx *sql.Tx, familyID, id string) (json.RawMessage, int, error) {
	row, err := storedb.New(tx).ChildRecord(ctx, storedb.ChildRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return nil, 0, err
	}
	value := map[string]any{"id": row.ID, "familyID": row.FamilyID, "nickname": row.Nickname, "birthDate": row.BirthDate, "predictionMode": row.PredictionMode, "quietHoursStartMinutes": row.QuietHoursStartMinutes, "quietHoursEndMinutes": row.QuietHoursEndMinutes, "timeZone": row.TimeZone, "growthReference": row.GrowthReference, "revision": row.Revision, "updatedAt": row.UpdatedAt}
	if row.ManualIntervalMinutes.Valid {
		value["manualIntervalMinutes"] = row.ManualIntervalMinutes.Int64
	}
	if row.DeletedAt.Valid {
		value["deletedAt"] = row.DeletedAt.String
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

func growthMeasurementJSON(ctx context.Context, tx *sql.Tx, familyID, id string) (json.RawMessage, int, error) {
	row, err := storedb.New(tx).GrowthMeasurementRecord(ctx, storedb.GrowthMeasurementRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return nil, 0, err
	}
	value := growthMeasurementRecord{ID: row.ID, FamilyID: row.FamilyID, ChildID: row.ChildID, Note: row.Note, Revision: int(row.Revision)}
	value.MeasuredAt, _ = parseTime(row.MeasuredAt)
	value.UpdatedAt, _ = parseTime(row.UpdatedAt)
	if row.WeightGrams.Valid {
		item := int(row.WeightGrams.Int64)
		value.WeightGrams = &item
	}
	if row.HeightMillimeters.Valid {
		item := int(row.HeightMillimeters.Int64)
		value.HeightMillimeters = &item
	}
	if row.DeletedAt.Valid {
		item, _ := parseTime(row.DeletedAt.String)
		value.DeletedAt = &item
	}
	encoded, err := json.Marshal(value)
	return encoded, value.Revision, err
}

func temperatureReadingJSON(ctx context.Context, tx *sql.Tx, familyID, id string) (json.RawMessage, int, error) {
	row, err := storedb.New(tx).TemperatureReadingRecord(ctx, storedb.TemperatureReadingRecordParams{ID: id, FamilyID: familyID})
	if err != nil {
		return nil, 0, err
	}
	value := temperatureReadingRecord{ID: row.ID, FamilyID: row.FamilyID, ChildID: row.ChildID, CentiCelsius: int(row.CentiCelsius), Note: row.Note, Revision: int(row.Revision)}
	value.MeasuredAt, _ = parseTime(row.MeasuredAt)
	value.UpdatedAt, _ = parseTime(row.UpdatedAt)
	if row.DeletedAt.Valid {
		item, _ := parseTime(row.DeletedAt.String)
		value.DeletedAt = &item
	}
	encoded, err := json.Marshal(value)
	return encoded, value.Revision, err
}

func validGrowthMeasurement(value growthMeasurementPayload) bool {
	if value.WeightGrams == nil && value.HeightMillimeters == nil {
		return false
	}
	if value.WeightGrams != nil && (*value.WeightGrams < 100 || *value.WeightGrams > 100000) {
		return false
	}
	return value.HeightMillimeters == nil || (*value.HeightMillimeters >= 100 && *value.HeightMillimeters <= 2500)
}

func validGrowthReference(value string) bool {
	return value == "none" || value == "girl" || value == "boy"
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
	return s.sleepForecastForChild(ctx, s.store.Queries, familyID, child)
}

func (s *Server) sleepForecastForChild(ctx context.Context, q *storedb.Queries, familyID string, child storedb.PredictionChildRow) *SleepForecast {
	rows, err := q.SweetSpotHistory(ctx, child.ID)
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
	location, err := cachedLocation(child.TimeZone)
	if err != nil {
		return nil
	}
	forecast := &SleepForecast{ChildID: child.ID}
	activeID, activeErr := q.ActiveSleepForChild(ctx, storedb.ActiveSleepForChildParams{FamilyID: familyID, ChildID: child.ID})
	if activeErr == nil {
		row, readErr := q.SleepRecord(ctx, storedb.SleepRecordParams{ID: activeID, FamilyID: familyID})
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

var locations sync.Map

// cachedLocation avoids re-reading zoneinfo on every forecast; a family's
// child time zone rarely changes and *time.Location is immutable.
func cachedLocation(name string) (*time.Location, error) {
	if location, ok := locations.Load(name); ok {
		return location.(*time.Location), nil
	}
	location, err := time.LoadLocation(name)
	if err != nil {
		return nil, err
	}
	locations.Store(name, location)
	return location, nil
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
