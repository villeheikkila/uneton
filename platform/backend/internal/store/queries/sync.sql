-- name: CommandResult :one
select result_json from commands
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: DeleteGrowthReferencePoints :exec
delete from growth_reference_points;

-- name: CreateGrowthReferencePoint :exec
insert into growth_reference_points(reference, metric, age_months, sd, value)
values (sqlc.arg(reference), sqlc.arg(metric), sqlc.arg(age_months), sqlc.arg(sd), sqlc.arg(value));

-- name: GrowthReferencePoints :many
select reference, metric, age_months, sd, value
from growth_reference_points
order by reference, metric, age_months, sd;

-- name: RecordCommand :exec
insert into commands(id, family_id, user_id, kind, result_json, created_at)
values (sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(user_id), sqlc.arg(kind), sqlc.arg(result_json), sqlc.arg(created_at))
on conflict(family_id, id) do nothing;

-- name: CreateChild :exec
insert into children(
  id, family_id, nickname, birth_date, prediction_mode,
  manual_interval_minutes, quiet_hours_start_minutes,
  quiet_hours_end_minutes, time_zone, growth_reference, revision, updated_at
) values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(nickname), sqlc.arg(birth_date),
  sqlc.arg(prediction_mode), sqlc.narg(manual_interval_minutes),
  sqlc.arg(quiet_hours_start_minutes), sqlc.arg(quiet_hours_end_minutes), sqlc.arg(time_zone), sqlc.arg(growth_reference), 1,
  sqlc.arg(updated_at)
);

-- name: ChildRevision :one
select revision from children
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id) and deleted_at is null;

-- name: UpdateChild :exec
update children set
  nickname=coalesce(nullif(sqlc.arg(nickname), ''), nickname),
  birth_date=coalesce(nullif(sqlc.arg(birth_date), ''), birth_date),
  prediction_mode=sqlc.arg(prediction_mode),
  manual_interval_minutes=sqlc.narg(manual_interval_minutes),
  quiet_hours_start_minutes=case when sqlc.arg(quiet_hours_start_minutes)>0 then sqlc.arg(quiet_hours_start_minutes) else quiet_hours_start_minutes end,
  quiet_hours_end_minutes=case when sqlc.arg(quiet_hours_end_minutes)>0 then sqlc.arg(quiet_hours_end_minutes) else quiet_hours_end_minutes end,
  time_zone=coalesce(nullif(sqlc.arg(time_zone), ''), time_zone),
  growth_reference=coalesce(nullif(sqlc.arg(growth_reference), ''), growth_reference),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: ChildRecord :one
select id, family_id, nickname, birth_date, prediction_mode,
  manual_interval_minutes, quiet_hours_start_minutes,
  quiet_hours_end_minutes, time_zone, growth_reference, revision, updated_at
from children
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: ActiveSleepForChild :one
select id from sleep_sessions
where family_id=sqlc.arg(family_id)
  and child_id=sqlc.arg(child_id)
  and ended_at is null
  and deleted_at is null
  and superseded_by_id is null
order by started_at, id limit 1;

-- name: ActiveSleepForFamily :one
select id, started_at, revision from sleep_sessions
where family_id=sqlc.arg(family_id)
  and ended_at is null
  and deleted_at is null
  and superseded_by_id is null
order by started_at limit 1;

-- name: ActiveSleepByID :one
select id, started_at, revision from sleep_sessions
where family_id=sqlc.arg(family_id)
  and id=sqlc.arg(id)
  and ended_at is null
  and deleted_at is null
  and superseded_by_id is null
order by started_at limit 1;

-- name: CreateActiveSleep :exec
insert into sleep_sessions(
  id, family_id, child_id, started_at, ended_at, revision,
  author_id, source, start_condition, sleep_location, end_condition,
  wake_mood, wake_reason, caregiver_intervened, updated_at
) values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(child_id),
  sqlc.arg(started_at), null, 1, sqlc.arg(author_id),
  sqlc.arg(source), sqlc.arg(start_condition), sqlc.arg(sleep_location),
  sqlc.arg(end_condition), sqlc.arg(wake_mood), sqlc.arg(wake_reason),
  sqlc.narg(caregiver_intervened), sqlc.arg(updated_at)
);

-- name: CreateSleep :exec
insert into sleep_sessions(
  id, family_id, child_id, started_at, ended_at, revision,
  author_id, source, start_condition, sleep_location, end_condition,
  wake_mood, wake_reason, caregiver_intervened, updated_at
) values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(child_id),
  sqlc.arg(started_at), sqlc.narg(ended_at), 1, sqlc.arg(author_id),
  sqlc.arg(source), sqlc.arg(start_condition), sqlc.arg(sleep_location),
  sqlc.arg(end_condition), sqlc.arg(wake_mood), sqlc.arg(wake_reason),
  sqlc.narg(caregiver_intervened), sqlc.arg(updated_at)
);

-- name: SleepRevision :one
select revision from sleep_sessions
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: ExistingSleepRevision :one
select revision from sleep_sessions
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id) and deleted_at is null;

-- name: EndSleep :exec
update sleep_sessions set
  ended_at=sqlc.arg(ended_at),
  end_condition=sqlc.arg(end_condition),
  wake_mood=sqlc.arg(wake_mood),
  wake_reason=sqlc.arg(wake_reason),
  caregiver_intervened=sqlc.narg(caregiver_intervened),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: UpdateSleep :exec
update sleep_sessions set
  started_at=sqlc.arg(started_at),
  ended_at=sqlc.narg(ended_at),
  start_condition=sqlc.arg(start_condition),
  sleep_location=sqlc.arg(sleep_location),
  end_condition=sqlc.arg(end_condition),
  wake_mood=sqlc.arg(wake_mood),
  wake_reason=sqlc.arg(wake_reason),
  caregiver_intervened=sqlc.narg(caregiver_intervened),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: DeleteSleep :exec
update sleep_sessions set
  deleted_at=sqlc.arg(deleted_at),
  revision=sqlc.arg(revision),
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id);

-- name: SleepRecord :one
select id, family_id, child_id, started_at, ended_at, revision,
  author_id, source, start_condition, sleep_location, end_condition,
  wake_mood, wake_reason, caregiver_intervened, superseded_by_id, updated_at, deleted_at
from sleep_sessions
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: SleepIntervals :many
select id, started_at, ended_at from sleep_sessions
where family_id=sqlc.arg(family_id)
  and child_id=sqlc.arg(child_id)
  and deleted_at is null
  and superseded_by_id is null
order by started_at, id;

-- name: MergeSleep :exec
update sleep_sessions set
  started_at=sqlc.arg(started_at),
  ended_at=sqlc.narg(ended_at),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id);

-- name: SupersedeSleep :exec
update sleep_sessions set
  superseded_by_id=sqlc.arg(superseded_by_id),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id);

-- name: CreateGrowthMeasurement :exec
insert into growth_measurements(
  id, family_id, child_id, measured_at, weight_grams, height_millimeters,
  note, revision, updated_at
) values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(child_id), sqlc.arg(measured_at),
  sqlc.narg(weight_grams), sqlc.narg(height_millimeters), sqlc.arg(note), 1,
  sqlc.arg(updated_at)
);

-- name: GrowthMeasurementRevision :one
select revision from growth_measurements
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: ExistingGrowthMeasurementRevision :one
select revision from growth_measurements
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id) and deleted_at is null;

-- name: UpdateGrowthMeasurement :exec
update growth_measurements set
  measured_at=sqlc.arg(measured_at),
  weight_grams=sqlc.narg(weight_grams),
  height_millimeters=sqlc.narg(height_millimeters),
  note=sqlc.arg(note),
  revision=revision+1,
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: DeleteGrowthMeasurement :exec
update growth_measurements set
  deleted_at=sqlc.arg(deleted_at),
  revision=sqlc.arg(revision),
  updated_at=sqlc.arg(updated_at)
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: GrowthMeasurementRecord :one
select id, family_id, child_id, measured_at, weight_grams, height_millimeters,
  note, revision, updated_at, deleted_at
from growth_measurements
where id=sqlc.arg(id) and family_id=sqlc.arg(family_id);

-- name: AppendEvent :exec
insert into sync_events(
  family_id, entity_type, entity_id, operation, revision, payload_json, created_at
) values (
  sqlc.arg(family_id), sqlc.arg(entity_type), sqlc.arg(entity_id),
  sqlc.arg(operation), sqlc.arg(revision), sqlc.arg(payload_json),
  sqlc.arg(created_at)
);

-- name: ReadEvents :many
select cursor, entity_type, entity_id, operation, revision, payload_json, created_at
from sync_events
where family_id=sqlc.arg(family_id) and cursor>sqlc.arg(cursor)
order by cursor limit sqlc.arg(result_limit);

-- name: LatestFamilyCursor :one
select cast(max(value) as integer) from (
  select coalesce(max(cursor), 0) as value from sync_events
  where sync_events.family_id=sqlc.arg(family_id)
  union all
  select coalesce(max(cursor), 0) as value from family_sync_snapshots
  where family_sync_snapshots.family_id=sqlc.arg(family_id)
) as latest_cursor;

-- name: FamilyEventCount :one
select count(*) from sync_events where family_id=sqlc.arg(family_id);

-- name: DeleteFamilyEventsThrough :exec
delete from sync_events
where family_id=sqlc.arg(family_id) and cursor<=sqlc.arg(cursor);

-- name: SnapshotChildIDs :many
select id from children
where family_id=sqlc.arg(family_id) and deleted_at is null
order by id;

-- name: SnapshotSleepIDs :many
select id from sleep_sessions
where family_id=sqlc.arg(family_id) and deleted_at is null
order by id;

-- name: FamilySyncSnapshot :one
select generation, cursor, entities_json, created_at
from family_sync_snapshots where family_id=sqlc.arg(family_id);

-- name: UpsertFamilySyncSnapshot :exec
insert into family_sync_snapshots(family_id, generation, cursor, entities_json, created_at)
values (sqlc.arg(family_id), sqlc.arg(generation), sqlc.arg(cursor), sqlc.arg(entities_json), sqlc.arg(created_at))
on conflict(family_id) do update set
  generation=excluded.generation,
  cursor=excluded.cursor,
  entities_json=excluded.entities_json,
  created_at=excluded.created_at;

-- name: QueueDelivery :exec
insert into deliveries(id, family_id, kind, payload_json, due_at, created_at)
values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(kind), sqlc.arg(payload_json),
  sqlc.arg(due_at), sqlc.arg(created_at)
);

-- name: ResetSendingDeliveries :exec
update deliveries set status='failed', last_error='backend restarted during delivery'
where status='sending';

-- name: DueDeliveries :many
select id, family_id, kind, payload_json, due_at, attempts
from deliveries
where status in ('pending', 'failed') and due_at<=sqlc.arg(now)
order by due_at, created_at
limit sqlc.arg(result_limit);

-- name: MarkDeliverySending :execrows
update deliveries set status='sending', attempts=attempts+1, last_error=null
where id=sqlc.arg(id) and status in ('pending', 'failed');

-- name: MarkDeliverySent :exec
update deliveries set status='sent', last_error=null where id=sqlc.arg(id);

-- name: MarkDeliveryFailed :exec
update deliveries set status='failed', last_error=sqlc.arg(last_error), due_at=sqlc.arg(due_at)
where id=sqlc.arg(id);

-- name: DeleteSentDeliveriesBefore :execrows
delete from deliveries
where status='sent' and created_at<sqlc.arg(created_at);

-- name: PredictionChild :one
select id, birth_date, prediction_mode, manual_interval_minutes, time_zone
from children
where family_id=sqlc.arg(family_id) and deleted_at is null
order by updated_at limit 1;

-- name: SweetSpotHistory :many
select started_at, ended_at, start_condition, sleep_location, end_condition,
  wake_mood, wake_reason, caregiver_intervened
from sleep_sessions
where child_id=sqlc.arg(child_id)
  and ended_at is not null
  and deleted_at is null
  and superseded_by_id is null
order by started_at;
