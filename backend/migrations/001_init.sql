-- KidsCam initial schema — backend.md §5.
-- Only pairings and device push tokens are stored: no media, no events, no
-- accounts. `k_auth` authenticates devices and decrypts nothing.

create table if not exists pairings (
  id         uuid primary key,
  k_auth     bytea not null,
  status     text not null check (status in ('pending', 'active', 'revoked')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);

-- Supports the daily purge of revoked and expired-pending pairings.
create index if not exists pairings_status_created_at_idx
  on pairings (status, created_at);

create table if not exists devices (
  id               uuid primary key,
  pairing_id       uuid not null references pairings (id) on delete cascade,
  role             text not null check (role in ('camera', 'viewer')),
  apns_token       text not null,
  apns_environment text not null
                   check (apns_environment in ('sandbox', 'production')),
  created_at       timestamptz not null default now(),
  last_seen_at     timestamptz
);

create index if not exists devices_pairing_id_idx on devices (pairing_id);

-- Exactly one camera per pairing; viewers are capped in application code
-- (backend.md §3: max 5) because the limit is configurable.
create unique index if not exists devices_one_camera_per_pairing
  on devices (pairing_id)
  where role = 'camera';

-- APNs 410 Unregistered cleanup deletes by token.
create index if not exists devices_apns_token_idx on devices (apns_token);
