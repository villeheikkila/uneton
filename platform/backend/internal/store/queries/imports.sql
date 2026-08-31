-- name: ImportTarget :one
select c.family_id, fm.user_id
from children as c
inner join family_members as fm
  on c.family_id=fm.family_id
 and fm.user_id=sqlc.arg(author_id)
 and fm.removed_at is null
where c.id=sqlc.arg(child_id)
  and c.family_id=sqlc.arg(family_id)
  and c.deleted_at is null;

-- name: ImportSleep :execrows
insert into sleep_sessions(
  id, family_id, child_id, started_at, ended_at, revision,
  author_id, source, updated_at
) values (
  sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(child_id),
  sqlc.arg(started_at), sqlc.arg(ended_at), 1,
  sqlc.arg(author_id), 'history_import', sqlc.arg(updated_at)
)
on conflict(id) do nothing;

-- name: ImportSleepContext :exec
update sleep_sessions set
  start_condition=sqlc.arg(start_condition),
  sleep_location=sqlc.arg(sleep_location),
  end_condition=sqlc.arg(end_condition)
where id=sqlc.arg(id);
