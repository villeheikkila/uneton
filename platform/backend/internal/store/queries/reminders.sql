-- name: ReminderCandidates :many
select devices.id as device_id, devices.apns_token, devices.apns_environment,
  devices.reminder_lead_minutes, devices.remote_reminders_until, devices.remote_reminders_from, devices.notification_language,
  children.id as child_id, children.family_id, children.birth_date, children.prediction_mode,
  children.manual_interval_minutes, children.time_zone
from devices
inner join family_members on devices.user_id=family_members.user_id
inner join children on family_members.family_id=children.family_id
where family_members.removed_at is null and children.deleted_at is null
  and devices.notifications_enabled=1 and devices.apns_token is not null
  and devices.remote_reminders_until>sqlc.arg(now);

-- name: ReminderAnchor :one
select id from sleep_sessions
where child_id=sqlc.arg(child_id) and ended_at is not null
  and deleted_at is null and superseded_by_id is null
order by started_at desc limit 1;

-- name: CancelPendingSleepReminders :exec
update sleep_reminders set status='cancelled' where status='pending';

-- name: UpsertSleepReminder :exec
insert into sleep_reminders (device_id, child_id, family_id, sleep_id, target_at, due_at, created_at)
values (sqlc.arg(device_id), sqlc.arg(child_id), sqlc.arg(family_id), sqlc.arg(sleep_id),
  sqlc.arg(target_at), sqlc.arg(due_at), sqlc.arg(created_at))
on conflict (device_id, child_id, sleep_id) do update
set target_at=excluded.target_at, due_at=excluded.due_at, status='pending'
where sleep_reminders.status!='attempted';

-- name: DueSleepReminders :many
select device_id, child_id, family_id, sleep_id, target_at, due_at
from sleep_reminders where status='pending' and due_at<=sqlc.arg(now)
order by due_at limit 20;

-- name: ClaimSleepReminder :execrows
update sleep_reminders set status='attempted'
where device_id=sqlc.arg(device_id) and child_id=sqlc.arg(child_id)
  and sleep_id=sqlc.arg(sleep_id) and status='pending';

-- name: CancelSleepReminder :exec
update sleep_reminders set status='cancelled'
where device_id=sqlc.arg(device_id) and child_id=sqlc.arg(child_id)
  and sleep_id=sqlc.arg(sleep_id) and status='pending';

-- name: DeleteOldSleepReminders :exec
delete from sleep_reminders where due_at<sqlc.arg(cutoff);
