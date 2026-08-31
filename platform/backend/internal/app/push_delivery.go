package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

func (s *Server) RunPushDeliveries(ctx context.Context) {
	if s.apns == nil {
		return
	}
	if err := s.store.Queries.ResetSendingDeliveries(ctx); err != nil {
		s.logger.ErrorContext(ctx, "could not reset interrupted push deliveries", "error", err)
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		s.runDuePushDeliveries(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) runDuePushDeliveries(ctx context.Context) {
	rows, err := s.store.Queries.DueDeliveries(ctx, storedb.DueDeliveriesParams{Now: formatTime(s.now().UTC()), ResultLimit: 20})
	if err != nil {
		s.logger.ErrorContext(ctx, "could not list due push deliveries", "error", err)
		return
	}
	for _, row := range rows {
		claimed, claimErr := s.store.Queries.MarkDeliverySending(ctx, row.ID)
		if claimErr != nil || claimed != 1 {
			continue
		}
		var payload activityDelivery
		var deliveryErr error
		if row.Kind == "familyChanged" {
			var familyPayload familyDelivery
			deliveryErr = json.Unmarshal(row.PayloadJson, &familyPayload)
			if deliveryErr == nil {
				deliveryErr = s.deliverFamilyChange(ctx, row.FamilyID, familyPayload.OriginDeviceID)
			}
		} else {
			deliveryErr = json.Unmarshal(row.PayloadJson, &payload)
			if deliveryErr == nil {
				event := map[string]string{"activityStart": "start", "activityEnd": "end"}[row.Kind]
				if event == "" {
					deliveryErr = fmt.Errorf("unsupported delivery kind %q", row.Kind)
				} else {
					deliveryErr = s.deliverSleepChange(ctx, row.FamilyID, payload.OriginDeviceID, event, payload.Sleep)
				}
			}
		}
		if deliveryErr == nil {
			_ = s.store.Queries.MarkDeliverySent(ctx, row.ID)
			continue
		}
		delay := time.Duration(1<<min(row.Attempts, int64(8))) * time.Second
		delay = min(delay, 5*time.Minute)
		_ = s.store.Queries.MarkDeliveryFailed(ctx, storedb.MarkDeliveryFailedParams{
			LastError: nullString(deliveryErr.Error()), DueAt: formatTime(s.now().UTC().Add(delay)), ID: row.ID,
		})
		s.logger.WarnContext(ctx, "push delivery will retry", "delivery_id", row.ID, "error", deliveryErr, "retry_in", delay)
	}
}

func (s *Server) deliverFamilyChange(ctx context.Context, familyID, originDeviceID string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	devices, err := s.store.Queries.FamilyNotificationDevices(ctx, familyID)
	if err != nil {
		return fmt.Errorf("list push devices: %w", err)
	}
	var transient []error
	for _, device := range devices {
		if device.ID == originDeviceID || !device.ApnsToken.Valid {
			continue
		}
		invalid, sendErr := s.apns.background(ctx, device.ApnsToken.String, device.ApnsEnvironment, familyID)
		if invalid {
			_ = s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: device.ID, ApnsToken: device.ApnsToken})
		}
		if sendErr != nil && !invalid {
			transient = append(transient, sendErr)
		}
	}
	return errors.Join(transient...)
}

func (s *Server) startMissingLiveActivities(deviceID string) {
	if s.apns == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := s.store.Queries.ActiveSleepsMissingFromDevice(ctx, deviceID)
	if err != nil {
		s.logger.WarnContext(ctx, "could not reconcile live activities", "device_id", deviceID, "error", err)
		return
	}
	for _, row := range rows {
		startedAt, parseErr := parseTime(row.StartedAt)
		if parseErr != nil {
			continue
		}
		attributes := map[string]any{
			"familyID": row.FamilyID, "childID": row.ChildID, "sessionID": row.ID,
			"childName": row.Nickname, "startedAt": appleReferenceSeconds(startedAt),
		}
		claimed, claimErr := s.store.Queries.ClaimLiveActivityStart(ctx, storedb.ClaimLiveActivityStartParams{
			SessionID: row.ID, DeviceID: deviceID, PushToStartToken: row.PushToStartToken.String, CreatedAt: formatTime(s.now().UTC()),
		})
		if claimErr != nil || claimed != 1 {
			continue
		}
		invalid, sendErr := s.apns.liveActivity(ctx, row.PushToStartToken.String, row.ApnsEnvironment, "start", attributes, map[string]any{}, "sleep-"+row.ID)
		if invalid {
			_ = s.store.Queries.DeletePushToStartToken(ctx, storedb.DeletePushToStartTokenParams{ID: deviceID, PushToStartToken: row.PushToStartToken})
		}
		if sendErr != nil && !invalid {
			s.logger.WarnContext(ctx, "live activity reconciliation failed", "device_id", deviceID, "session_id", row.ID, "error", sendErr)
		}
		if sendErr != nil {
			_ = s.store.Queries.ReleaseLiveActivityStart(ctx, storedb.ReleaseLiveActivityStartParams{SessionID: row.ID, DeviceID: deviceID, PushToStartToken: row.PushToStartToken.String})
		}
	}
}

func (s *Server) deliverSleepChange(ctx context.Context, familyID, originDeviceID, event string, sleep sleepRecord) error {
	if s.apns == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	child, err := s.store.Queries.ChildNotificationContext(ctx, storedb.ChildNotificationContextParams{SessionID: sleep.ID, FamilyID: familyID})
	if err != nil {
		return fmt.Errorf("load push context: %w", err)
	}
	devices, err := s.store.Queries.FamilyNotificationDevices(ctx, familyID)
	if err != nil {
		return fmt.Errorf("list push devices: %w", err)
	}
	var transient []error
	if event == "start" {
		attributes := map[string]any{"familyID": familyID, "childID": sleep.ChildID, "sessionID": sleep.ID, "childName": child.Nickname, "startedAt": appleReferenceSeconds(sleep.StartedAt)}
		for _, device := range devices {
			if device.ID != originDeviceID && device.NotificationsEnabled == 1 && device.ApnsToken.Valid {
				invalid, sendErr := s.apns.alert(ctx, device.ApnsToken.String, device.ApnsEnvironment, child.Nickname+" is sleeping", "Sleep started just now.", "sleep-"+sleep.ID)
				if invalid {
					_ = s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: device.ID, ApnsToken: device.ApnsToken})
				}
				if sendErr != nil {
					s.logger.WarnContext(ctx, "ordinary push failed", "device_id", device.ID, "error", sendErr)
					if !invalid {
						transient = append(transient, sendErr)
					}
				}
			}
			if device.ID != originDeviceID && device.LiveActivitiesEnabled == 1 && device.PushToStartToken.Valid {
				claimed, claimErr := s.store.Queries.ClaimLiveActivityStart(ctx, storedb.ClaimLiveActivityStartParams{
					SessionID: sleep.ID, DeviceID: device.ID, PushToStartToken: device.PushToStartToken.String, CreatedAt: formatTime(s.now().UTC()),
				})
				if claimErr != nil {
					transient = append(transient, claimErr)
					continue
				}
				if claimed != 1 {
					continue
				}
				invalid, sendErr := s.apns.liveActivity(ctx, device.PushToStartToken.String, device.ApnsEnvironment, "start", attributes, map[string]any{}, "sleep-"+sleep.ID)
				if invalid {
					_ = s.store.Queries.DeletePushToStartToken(ctx, storedb.DeletePushToStartTokenParams{ID: device.ID, PushToStartToken: device.PushToStartToken})
				}
				if sendErr != nil {
					s.logger.WarnContext(ctx, "live activity start push failed", "device_id", device.ID, "error", sendErr)
					_ = s.store.Queries.ReleaseLiveActivityStart(ctx, storedb.ReleaseLiveActivityStartParams{SessionID: sleep.ID, DeviceID: device.ID, PushToStartToken: device.PushToStartToken.String})
					if !invalid {
						transient = append(transient, sendErr)
					}
				}
			}
			if device.ID != originDeviceID && device.ApnsToken.Valid {
				invalid, sendErr := s.apns.background(ctx, device.ApnsToken.String, device.ApnsEnvironment, familyID)
				if invalid {
					_ = s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: device.ID, ApnsToken: device.ApnsToken})
				}
				if sendErr != nil && !invalid {
					transient = append(transient, sendErr)
				}
			}
		}
		return errors.Join(transient...)
	}
	for _, device := range devices {
		if device.ID != originDeviceID && device.NotificationsEnabled == 1 && device.ApnsToken.Valid {
			invalid, sendErr := s.apns.alert(ctx, device.ApnsToken.String, device.ApnsEnvironment, child.Nickname+" woke up", "Sleep ended just now.", "sleep-"+sleep.ID)
			if invalid {
				_ = s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: device.ID, ApnsToken: device.ApnsToken})
			}
			if sendErr != nil {
				s.logger.WarnContext(ctx, "ordinary push failed", "device_id", device.ID, "error", sendErr)
				if !invalid {
					transient = append(transient, sendErr)
				}
			}
		}
		if device.ID != originDeviceID && device.ApnsToken.Valid {
			invalid, sendErr := s.apns.background(ctx, device.ApnsToken.String, device.ApnsEnvironment, familyID)
			if invalid {
				_ = s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: device.ID, ApnsToken: device.ApnsToken})
			}
			if sendErr != nil && !invalid {
				transient = append(transient, sendErr)
			}
		}
	}
	tokens, err := s.store.Queries.SessionLiveActivityTokens(ctx, sleep.ID)
	if err != nil {
		return fmt.Errorf("list live activity tokens: %w", err)
	}
	endedAt := s.now().UTC()
	if sleep.EndedAt != nil {
		endedAt = *sleep.EndedAt
	}
	for _, token := range tokens {
		invalid, sendErr := s.apns.liveActivity(ctx, token.Token, token.ApnsEnvironment, "end", nil, map[string]any{"endedAt": appleReferenceSeconds(endedAt)}, "sleep-"+sleep.ID)
		if invalid {
			_ = s.store.Queries.DeleteLiveActivityToken(ctx, token.Token)
		}
		if sendErr != nil {
			s.logger.WarnContext(ctx, "live activity end push failed", "device_id", token.DeviceID, "error", sendErr)
			if !invalid {
				transient = append(transient, sendErr)
			}
		}
	}
	pending, err := s.store.Queries.PendingLiveActivityTokens(ctx, sleep.ID)
	if err != nil {
		transient = append(transient, err)
	} else if pending > 0 {
		transient = append(transient, fmt.Errorf("waiting for %d live activity push tokens", pending))
	}
	if len(transient) == 0 {
		_ = s.store.Queries.DeleteLiveActivityTokens(ctx, sleep.ID)
	}
	return errors.Join(transient...)
}
