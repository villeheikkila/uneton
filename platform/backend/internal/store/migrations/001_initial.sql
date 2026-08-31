create table users (
  id text primary key not null,
  apple_subject text not null unique,
  display_name text not null default '',
  apple_refresh_token_ciphertext blob,
  created_at text not null,
  deleted_at text
) strict;

create table families (
  id text primary key not null,
  name text not null default '',
  owner_id text not null references users(id),
  created_at text not null
) strict;

create table family_members (
  family_id text not null references families(id) on delete cascade,
  user_id text not null references users(id) on delete cascade,
  role text not null check (role in ('owner', 'caregiver')),
  joined_at text not null,
  removed_at text,
  primary key (family_id, user_id)
) strict;
create index family_members_user on family_members(user_id, removed_at);

create table invites (
  id text primary key not null,
  family_id text not null references families(id) on delete cascade,
  token_hash blob not null unique,
  created_by text not null references users(id),
  expires_at text not null,
  claimed_by text references users(id),
  claimed_at text,
  created_at text not null
) strict;

create table children (
  id text primary key not null,
  family_id text not null references families(id) on delete cascade,
  nickname text not null,
  birth_date text not null,
  prediction_mode text not null default 'adaptive' check (prediction_mode in ('adaptive', 'manual')),
  manual_interval_minutes integer,
  quiet_hours_start_minutes integer not null default 1200,
  quiet_hours_end_minutes integer not null default 360,
  time_zone text not null default 'Europe/Helsinki',
  growth_reference text not null default 'none' check (growth_reference in ('none', 'girl', 'boy')),
  revision integer not null default 1,
  updated_at text not null,
  deleted_at text,
  unique (family_id, id)
) strict;
create index children_family on children(family_id, deleted_at);

create table sleep_sessions (
  id text primary key not null,
  family_id text not null references families(id) on delete cascade,
  child_id text not null,
  started_at text not null,
  ended_at text,
  revision integer not null default 1,
  author_id text not null references users(id),
  source text not null default 'phone',
  start_condition text not null default '',
  sleep_location text not null default '',
  end_condition text not null default '',
  wake_mood text not null default 'unknown' check (wake_mood in ('unknown', 'calm', 'fussy', 'crying')),
  wake_reason text not null default 'unknown' check (wake_reason in ('unknown', 'natural', 'feed', 'discomfort', 'caregiver')),
  caregiver_intervened integer check (caregiver_intervened is null or caregiver_intervened in (0, 1)),
  superseded_by_id text references sleep_sessions(id),
  updated_at text not null,
  deleted_at text,
  foreign key (family_id, child_id) references children(family_id, id) on delete cascade
) strict;
create index sleep_sessions_child_time on sleep_sessions(child_id, started_at desc);
create index sleep_sessions_active on sleep_sessions(child_id, ended_at, deleted_at, superseded_by_id);

create table growth_measurements (
  id text primary key not null,
  family_id text not null references families(id) on delete cascade,
  child_id text not null,
  measured_at text not null,
  weight_grams integer,
  height_millimeters integer,
  note text not null default '',
  revision integer not null default 1,
  updated_at text not null,
  deleted_at text,
  check (weight_grams is not null or height_millimeters is not null),
  check (weight_grams is null or weight_grams between 100 and 100000),
  check (height_millimeters is null or height_millimeters between 100 and 2500),
  foreign key (family_id, child_id) references children(family_id, id) on delete cascade
) strict;
create index growth_measurements_child_time on growth_measurements(child_id, measured_at desc);

-- Private, locally seeded reference data used to draw growth charts. It has no
-- family ownership and is never emitted through the synchronization event log.
create table growth_reference_points (
  reference text not null check (reference in ('girl', 'boy')),
  metric text not null check (metric in ('height', 'weight')),
  age_months integer not null check (age_months between 0 and 240),
  sd integer not null check (sd between -3 and 3),
  value integer not null check (value > 0),
  primary key (reference, metric, age_months, sd)
) strict;

create table devices (
  id text primary key not null,
  user_id text not null references users(id) on delete cascade,
  refresh_token_hash blob,
  refresh_expires_at text,
  apns_token text,
  push_to_start_token text,
  apns_environment text not null default 'development',
  notifications_enabled integer not null default 1,
  live_activities_enabled integer not null default 1,
  reminder_lead_minutes integer not null default 15,
  last_seen_at text not null
) strict;
create index devices_user on devices(user_id);

create table live_activity_tokens (
  session_id text not null references sleep_sessions(id) on delete cascade,
  device_id text not null references devices(id) on delete cascade,
  token text not null,
  apns_environment text not null check (apns_environment in ('development', 'production')),
  updated_at text not null,
  primary key (session_id, device_id)
) strict;

create table live_activity_starts (
  session_id text not null references sleep_sessions(id) on delete cascade,
  device_id text not null references devices(id) on delete cascade,
  push_to_start_token text not null,
  created_at text not null,
  primary key (session_id, device_id)
) strict;
create unique index live_activity_tokens_token on live_activity_tokens(token);

create table commands (
  id text not null,
  family_id text not null references families(id) on delete cascade,
  user_id text not null references users(id),
  kind text not null,
  result_json blob not null,
  created_at text not null,
  primary key (family_id, id)
) strict;

create table sync_events (
  cursor integer primary key autoincrement,
  family_id text not null references families(id) on delete cascade,
  entity_type text not null,
  entity_id text not null,
  operation text not null check (operation in ('upsert', 'delete')),
  revision integer not null,
  payload_json blob not null,
  created_at text not null
) strict;
create index sync_events_family_cursor on sync_events(family_id, cursor);

create table family_sync_snapshots (
  family_id text primary key not null references families(id) on delete cascade,
  generation text not null,
  cursor integer not null,
  entities_json blob not null,
  created_at text not null
) strict;

create table deliveries (
  id text primary key not null,
  family_id text not null references families(id) on delete cascade,
  kind text not null,
  payload_json blob not null,
  due_at text not null,
  attempts integer not null default 0,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed')),
  last_error text,
  created_at text not null
) strict;
create index deliveries_due on deliveries(status, due_at);
