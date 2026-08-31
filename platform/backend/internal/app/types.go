package app

import (
	"encoding/hex"
	"encoding/json"
	"time"
)

func validPushToken(value string) bool {
	if len(value) < 32 || len(value) > 512 || len(value)%2 != 0 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func boolInt(value bool) int64 {
	if value {
		return 1
	}
	return 0
}

type Command struct {
	ID               string          `json:"id"`
	Kind             string          `json:"kind"`
	ExpectedRevision *int            `json:"expectedRevision,omitempty"`
	Payload          json.RawMessage `json:"payload"`
}

type SyncRequest struct {
	Cursor     int64     `json:"cursor"`
	Generation string    `json:"generation"`
	DeviceID   string    `json:"deviceID"`
	Commands   []Command `json:"commands"`
	Limit      int       `json:"limit,omitempty"`
}

type CommandResult struct {
	ID       string          `json:"id"`
	Status   string          `json:"status"`
	Error    string          `json:"error,omitempty"`
	EntityID string          `json:"entityID,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
}

type Event struct {
	Cursor     int64           `json:"cursor"`
	EntityType string          `json:"entityType"`
	EntityID   string          `json:"entityID"`
	Operation  string          `json:"operation"`
	Revision   int             `json:"revision"`
	Payload    json.RawMessage `json:"payload"`
	CreatedAt  time.Time       `json:"createdAt"`
}

type SnapshotEntity struct {
	EntityType string          `json:"entityType"`
	EntityID   string          `json:"entityID"`
	Revision   int             `json:"revision"`
	Payload    json.RawMessage `json:"payload"`
}

type FamilySnapshot struct {
	Cursor    int64            `json:"cursor"`
	Entities  []SnapshotEntity `json:"entities"`
	CreatedAt time.Time        `json:"createdAt"`
}

type Prediction struct {
	TargetAt         time.Time `json:"targetAt"`
	RangeStartAt     time.Time `json:"rangeStartAt"`
	RangeEndAt       time.Time `json:"rangeEndAt"`
	Confidence       string    `json:"confidence"`
	Explanation      string    `json:"explanation"`
	AlgorithmVersion int       `json:"algorithmVersion"`
	Kind             string    `json:"kind"`
	SampleCount      int       `json:"sampleCount"`
}

type SleepForecast struct {
	ChildID                string      `json:"childID"`
	ActiveSleepID          *string     `json:"activeSleepID,omitempty"`
	WakeEstimate           *Prediction `json:"wakeEstimate,omitempty"`
	NextSleepEstimate      *Prediction `json:"nextSleepEstimate,omitempty"`
	NextSleepIsProvisional bool        `json:"nextSleepIsProvisional"`
}

type SyncResponse struct {
	CommandResults    []CommandResult `json:"commandResults"`
	Events            []Event         `json:"events"`
	NextCursor        int64           `json:"nextCursor"`
	HasMore           bool            `json:"hasMore"`
	NextSleepEstimate *Prediction     `json:"nextSleepEstimate,omitempty"`
	ServerTime        time.Time       `json:"serverTime"`
	SleepForecast     *SleepForecast  `json:"sleepForecast,omitempty"`
	Generation        string          `json:"generation"`
	Snapshot          *FamilySnapshot `json:"snapshot,omitempty"`
	ResetRequired     bool            `json:"resetRequired"`
}

type principal struct {
	UserID    string
	DeviceID  string
	ExpiresAt time.Time
}
