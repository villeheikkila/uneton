-- name: UserIDByAppleSubject :one
select id from users where apple_subject = sqlc.arg(apple_subject);

-- name: CreateUser :exec
insert into users(id, apple_subject, display_name, apple_refresh_token_ciphertext, created_at)
values (sqlc.arg(id), sqlc.arg(apple_subject), sqlc.arg(display_name), sqlc.arg(apple_refresh_token_ciphertext), sqlc.arg(created_at));

-- name: UpdateAppleRefreshToken :exec
update users set apple_refresh_token_ciphertext=sqlc.arg(apple_refresh_token_ciphertext)
where id=sqlc.arg(id) and deleted_at is null;

-- name: UserAppleRefreshToken :one
select apple_refresh_token_ciphertext from users
where id=sqlc.arg(id) and deleted_at is null;

-- name: AppleRefreshTokens :many
select id, apple_refresh_token_ciphertext from users
where deleted_at is null and apple_refresh_token_ciphertext is not null
order by id;

-- name: UpsertDevice :exec
insert into devices(id, user_id, refresh_token_hash, refresh_expires_at, last_seen_at)
values (sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(refresh_token_hash), sqlc.arg(refresh_expires_at), sqlc.arg(last_seen_at))
on conflict(id) do update set
  user_id=excluded.user_id,
  refresh_token_hash=excluded.refresh_token_hash,
  refresh_expires_at=excluded.refresh_expires_at,
  last_seen_at=excluded.last_seen_at;

-- name: DeviceSession :one
select user_id, refresh_token_hash, refresh_expires_at
from devices
where id = sqlc.arg(id);

-- name: ActiveDeviceSession :one
select exists(
  select 1 from devices
  inner join users on devices.user_id=users.id
  where devices.id=sqlc.arg(id)
    and devices.user_id=sqlc.arg(user_id)
    and users.deleted_at is null
);

-- name: TouchDeviceSession :execrows
update devices set
  refresh_expires_at=sqlc.arg(refresh_expires_at),
  last_seen_at=sqlc.arg(last_seen_at)
where id=sqlc.arg(id) and refresh_token_hash=sqlc.arg(refresh_token_hash);

-- name: DeleteDeviceForUser :execrows
delete from devices where id=sqlc.arg(id) and user_id=sqlc.arg(user_id);

-- name: DevicePushSettings :one
select apns_token, push_to_start_token, apns_environment,
  notifications_enabled, live_activities_enabled, reminder_lead_minutes
from devices where id=sqlc.arg(id) and user_id=sqlc.arg(user_id);

-- name: UpdateDevicePushSettings :execrows
update devices set
  apns_token=sqlc.narg(apns_token),
  push_to_start_token=sqlc.narg(push_to_start_token),
  apns_environment=sqlc.arg(apns_environment),
  notifications_enabled=sqlc.arg(notifications_enabled),
  live_activities_enabled=sqlc.arg(live_activities_enabled),
  reminder_lead_minutes=sqlc.arg(reminder_lead_minutes),
  last_seen_at=sqlc.arg(last_seen_at)
where id=sqlc.arg(id) and user_id=sqlc.arg(user_id);

-- name: RegisterLiveActivity :exec
insert into live_activity_tokens(session_id, device_id, token, apns_environment, updated_at)
values (sqlc.arg(session_id), sqlc.arg(device_id), sqlc.arg(token), sqlc.arg(apns_environment), sqlc.arg(updated_at))
on conflict(session_id, device_id) do update set
  token=excluded.token, apns_environment=excluded.apns_environment, updated_at=excluded.updated_at;

-- name: ClaimLiveActivityStart :execrows
insert into live_activity_starts(session_id, device_id, push_to_start_token, created_at)
values (sqlc.arg(session_id), sqlc.arg(device_id), sqlc.arg(push_to_start_token), sqlc.arg(created_at))
on conflict(session_id, device_id) do nothing;

-- name: ReleaseLiveActivityStart :exec
delete from live_activity_starts
where session_id=sqlc.arg(session_id) and device_id=sqlc.arg(device_id)
  and push_to_start_token=sqlc.arg(push_to_start_token);

-- name: PendingLiveActivityTokens :one
select count(*) from live_activity_starts
left join live_activity_tokens
  on live_activity_starts.session_id=live_activity_tokens.session_id
  and live_activity_starts.device_id=live_activity_tokens.device_id
where live_activity_starts.session_id=sqlc.arg(session_id)
  and live_activity_tokens.token is null;

-- name: CanRegisterLiveActivity :one
select exists(
  select 1 from sleep_sessions
  inner join family_members on sleep_sessions.family_id=family_members.family_id
  where sleep_sessions.id=sqlc.arg(session_id)
    and family_members.user_id=sqlc.arg(user_id)
    and family_members.removed_at is null
);

-- name: FamilyNotificationDevices :many
select distinct devices.id, devices.apns_token, devices.push_to_start_token,
  devices.apns_environment, devices.notifications_enabled, devices.live_activities_enabled
from devices
inner join family_members on devices.user_id=family_members.user_id
where family_members.family_id=sqlc.arg(family_id)
  and family_members.removed_at is null;

-- name: SessionLiveActivityTokens :many
select live_activity_tokens.device_id, live_activity_tokens.token, live_activity_tokens.apns_environment
from live_activity_tokens
where live_activity_tokens.session_id=sqlc.arg(session_id);

-- name: DeleteLiveActivityTokens :exec
delete from live_activity_tokens where session_id=sqlc.arg(session_id);

-- name: DeletePushToken :exec
update devices set apns_token=null where id=sqlc.arg(id) and apns_token=sqlc.arg(apns_token);

-- name: DeletePushToStartToken :exec
update devices set push_to_start_token=null where id=sqlc.arg(id) and push_to_start_token=sqlc.arg(push_to_start_token);

-- name: DeleteLiveActivityToken :exec
delete from live_activity_tokens where token=sqlc.arg(token);

-- name: ChildNotificationContext :one
select children.nickname, sleep_sessions.started_at
from sleep_sessions inner join children on sleep_sessions.child_id=children.id
where sleep_sessions.id=sqlc.arg(session_id) and sleep_sessions.family_id=sqlc.arg(family_id);

-- name: ActiveSleepsMissingFromDevice :many
select sleep_sessions.id, sleep_sessions.family_id, sleep_sessions.child_id,
  sleep_sessions.started_at, children.nickname, devices.push_to_start_token,
  devices.apns_environment
from devices
inner join family_members on devices.user_id=family_members.user_id and family_members.removed_at is null
inner join sleep_sessions on family_members.family_id=sleep_sessions.family_id
inner join children on sleep_sessions.child_id=children.id
where devices.id=sqlc.arg(device_id)
  and devices.live_activities_enabled=1
  and devices.push_to_start_token is not null
  and sleep_sessions.ended_at is null
  and sleep_sessions.deleted_at is null
  and sleep_sessions.superseded_by_id is null
  and not exists (
    select 1 from live_activity_starts
    where live_activity_starts.session_id=sleep_sessions.id
      and live_activity_starts.device_id=devices.id
  );

-- name: RemoveFamilyMemberships :exec
delete from family_members where user_id=sqlc.arg(user_id);

-- name: DeleteUserDevices :exec
delete from devices where user_id=sqlc.arg(user_id);

-- name: AnonymizeUser :execrows
update users set
  apple_subject=sqlc.arg(apple_subject),
  display_name='',
  apple_refresh_token_ciphertext=null,
  deleted_at=sqlc.arg(deleted_at)
where id=sqlc.arg(id) and deleted_at is null;
