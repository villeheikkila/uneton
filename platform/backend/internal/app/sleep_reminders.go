package app

import (
	"context"
	"errors"
	"time"

	"solutions.bytesized/uneton/platform/backend/internal/store/storedb"
)

// A reminder is presentation derived from a single acknowledged wake episode.
// Its durable identity survives retries, schedule edits, and worker restarts.
type sleepReminderPlan struct {
	device               storedb.ReminderCandidatesRow
	sleepID              string
	target, due, expires time.Time
}

func (s *Server) planSleepReminder(ctx context.Context, q *storedb.Queries, device storedb.ReminderCandidatesRow, now time.Time) (*sleepReminderPlan, error) {
	until, err := parseTime(device.RemoteRemindersUntil.String)
	if err != nil {
		return nil, err
	}
	forecast := s.sleepForecastForChild(ctx, q, device.FamilyID, storedb.PredictionChildRow{
		ID: device.ChildID, BirthDate: device.BirthDate, PredictionMode: device.PredictionMode,
		ManualIntervalMinutes: device.ManualIntervalMinutes, TimeZone: device.TimeZone,
	})
	if forecast == nil || forecast.NextSleepIsProvisional || forecast.ActiveSleepID != nil || forecast.NextSleepEstimate == nil {
		return nil, nil
	}
	from, err := parseTime(device.RemoteRemindersFrom.String)
	if err != nil {
		return nil, err
	}
	target := forecast.NextSleepEstimate.TargetAt
	due := target.Add(-time.Duration(device.ReminderLeadMinutes) * time.Minute)
	deadline := target
	if device.ReminderLeadMinutes == 0 {
		deadline = target.Add(5 * time.Minute)
	}
	// Never backfill a stale estimate; a brief worker outage gets a five-minute grace.
	if due.Before(from) || !due.Before(until) || !due.Add(5*time.Minute).After(now) || !deadline.After(now) {
		return nil, nil
	}
	sleepID, err := q.ReminderAnchor(ctx, device.ChildID)
	if err != nil {
		return nil, err
	}
	expires := due.Add(5 * time.Minute)
	if deadline.Before(expires) {
		expires = deadline
	}
	if until.Before(expires) {
		expires = until
	}
	return &sleepReminderPlan{device: device, sleepID: sleepID, target: target, due: due, expires: expires}, nil
}

func (s *Server) reconcileSleepReminders(ctx context.Context) error {
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	now := s.now().UTC()
	devices, err := q.ReminderCandidates(ctx, nullString(formatTime(now)))
	if err != nil {
		return err
	}
	if err = q.CancelPendingSleepReminders(ctx); err != nil {
		return err
	}
	for _, device := range devices {
		plan, planErr := s.planSleepReminder(ctx, q, device, now)
		if planErr != nil {
			return planErr
		}
		if plan == nil {
			continue
		}
		if err = q.UpsertSleepReminder(ctx, storedb.UpsertSleepReminderParams{
			DeviceID: device.DeviceID, ChildID: device.ChildID, FamilyID: device.FamilyID,
			SleepID: plan.sleepID, TargetAt: formatTime(plan.target), DueAt: formatTime(plan.due), CreatedAt: formatTime(now),
		}); err != nil {
			return err
		}
	}
	if err = q.DeleteOldSleepReminders(ctx, formatTime(now.Add(-7*24*time.Hour))); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Server) sendDueSleepReminders(ctx context.Context) {
	if s.apns == nil {
		return
	}
	rows, err := s.store.Queries.DueSleepReminders(ctx, formatTime(s.now().UTC()))
	if err != nil {
		s.logger.ErrorContext(ctx, "could not read sleep reminders", "error", err)
		return
	}
	for _, row := range rows {
		if err := s.sendSleepReminder(ctx, row); err != nil {
			s.logger.WarnContext(ctx, "sleep reminder submission failed", "error", err)
		}
	}
}

func (s *Server) sendSleepReminder(ctx context.Context, row storedb.DueSleepRemindersRow) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	q := s.store.Queries.WithTx(tx)
	// Recheck membership, token, switches, lease, current wake and estimate in
	// one database snapshot, immediately before claiming an APNs submission.
	devices, err := q.ReminderCandidates(ctx, nullString(formatTime(s.now().UTC())))
	if err != nil {
		return err
	}
	var plan *sleepReminderPlan
	for _, device := range devices {
		if device.DeviceID == row.DeviceID && device.ChildID == row.ChildID {
			plan, err = s.planSleepReminder(ctx, q, device, s.now().UTC())
			if err != nil {
				return err
			}
			break
		}
	}
	if plan == nil || plan.sleepID != row.SleepID || formatTime(plan.target) != row.TargetAt || formatTime(plan.due) != row.DueAt {
		if err = q.CancelSleepReminder(ctx, storedb.CancelSleepReminderParams{DeviceID: row.DeviceID, ChildID: row.ChildID, SleepID: row.SleepID}); err != nil {
			return err
		}
		return tx.Commit()
	}
	claimed, err := q.ClaimSleepReminder(ctx, storedb.ClaimSleepReminderParams{DeviceID: row.DeviceID, ChildID: row.ChildID, SleepID: row.SleepID})
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	if claimed != 1 {
		return nil
	}
	// Claim before network I/O and do not retry ambiguous responses. A missed
	// planning nudge is preferable to duplicate alerts after a process crash.
	invalid, sendErr := s.apns.sleepReminder(ctx, plan.device.ApnsToken.String, plan.device.ApnsEnvironment,
		plan.device.NotificationLanguage, "reminder-"+row.ChildID, plan.expires)
	if invalid {
		clearErr := s.store.Queries.DeletePushToken(ctx, storedb.DeletePushTokenParams{ID: row.DeviceID, ApnsToken: plan.device.ApnsToken})
		return errors.Join(sendErr, clearErr)
	}
	return sendErr
}

func (p *APNSProvider) sleepReminder(ctx context.Context, token, environment, language, collapseID string, expires time.Time) (bool, error) {
	title, body := "Sleep window is approaching", "Your baby may be ready for sleep soon."
	if language == "fi" {
		title, body = "Uniaika lähestyy", "Vauvasi saattaa olla pian valmis nukkumaan."
	}
	return p.sendWithExpiration(ctx, token, environment, "alert", p.topic, "10", collapseID, expires,
		map[string]any{"aps": map[string]any{"alert": map[string]string{"title": title, "body": body}, "sound": "default"}})
}
