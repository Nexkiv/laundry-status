-- Laundry status pipeline: storage, the device write path, public read views, and jobs.
--
-- Layout
--   laundry.*  private schema, never exposed by the Data API (PostgREST only serves `public`).
--   public.*   only what the internet may touch: read views + two RPCs (ingest, subscribe_push).
--
-- Every value the board sends is a number code (no free text), checked against fixed ranges, so
-- nothing a device writes can ever be rendered as markup on the public page.

------------------------------------------------------------------------------------------------
-- 0. Lock down the defaults first.
-- Supabase grants anon/authenticated ALL on new tables/views in `public` and EXECUTE on new
-- functions (Postgres also grants EXECUTE to PUBLIC by default). A plain view is auto-updatable,
-- so a default grant would let anyone with the public key write or delete through it.
------------------------------------------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated, public;
alter default privileges for role postgres revoke execute on functions from public;

drop extension if exists pg_graphql;   -- second API surface over the same objects; not used

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net;   -- functions live in schema net

create schema if not exists laundry;
revoke all on schema laundry from public, anon, authenticated;

------------------------------------------------------------------------------------------------
-- 1. Code tables. The board sends numbers; names live here, written by us, not by the device.
------------------------------------------------------------------------------------------------
create table laundry.state_codes (code smallint primary key, name text not null unique);
insert into laundry.state_codes values
  (0, 'free'), (1, 'in_use'), (2, 'out_of_order'), (3, 'offline'), (4, 'no_data'), (5, 'format_changed');

create table laundry.listener_codes (code smallint primary key, name text not null unique);
insert into laundry.listener_codes values (0, 'waiting'), (1, 'online'), (2, 'offline'), (3, 'deaf');

-- Same order as payrange::Event::Type in firmware/payrange.h, so the board sends the enum value.
create table laundry.event_codes (code smallint primary key, name text not null unique);
insert into laundry.event_codes values
  (0, 'washer_free'), (1, 'washer_taken'), (2, 'dryer_paid'), (3, 'unknown_module'), (4, 'format_changed'),
  (5, 'listener_lost'), (6, 'listener_back'), (7, 'listener_deaf'), (8, 'listener_restarted');

------------------------------------------------------------------------------------------------
-- 2. Tables
------------------------------------------------------------------------------------------------
-- Writers. Only a sha256 of each token is stored. Device 0 is the one-time historical seed;
-- its token hash is random, so it can never authenticate over the API.
create table laundry.devices (
  id           smallint primary key,
  name         text  not null unique,
  token_sha256 bytea not null unique check (octet_length(token_sha256) = 32)
);

-- One row per board power-up. A reboot starts a new boot_id, which is how gaps get explained.
create table laundry.boots (
  boot_id        uuid primary key,
  device_id      smallint    not null references laundry.devices,
  first_received timestamptz not null
);
create index on laundry.boots (device_id, first_received);

-- Silver: one row per minute of board time (plus extra rows when a change forces a flush).
create table laundry.snapshots (
  boot_id     uuid        not null references laundry.boots,
  seq         integer     not null check (seq >= 0),
  received_at timestamptz not null,               -- server clock, always set by the server
  observed_at timestamptz not null,               -- received_at - age the row spent in the outbox
  listener    smallint    not null references laundry.listener_codes,
  link_rssi   smallint    check (link_rssi between -127 and 0),
  frames_ok   bigint      not null check (frames_ok >= 0),
  frames_lost bigint      not null check (frames_lost >= 0),
  heap_kb     smallint    not null check (heap_kb >= 0),
  block_kb    smallint    not null check (block_kb >= 0),   -- largest free block (TLS needs ~40 KB)
  dropped     integer     not null check (dropped >= 0),    -- outbox rows lost to overflow, this boot
  rejected    integer     not null check (rejected >= 0),   -- batches the server refused (dead letters)
  skipped     integer     not null check (skipped >= 0),    -- sends skipped by the heap guard
  primary key (boot_id, seq)
);
create index on laundry.snapshots (observed_at desc);
create index on laundry.snapshots (received_at desc);

create table laundry.machine_readings (
  boot_id       uuid        not null,
  seq           integer     not null,
  machine       smallint    not null check (machine between 1 and 6),
  observed_at   timestamptz not null,
  state         smallint    not null references laundry.state_codes,
  state_since   timestamptz,                       -- null when unknown (no data yet)
  since_restart boolean     not null,              -- true: the state began before the board booted
  rssi          smallint    check (rssi between -127 and 0),
  primary key (boot_id, seq, machine),
  foreign key (boot_id, seq) references laundry.snapshots on delete cascade
);
create index on laundry.machine_readings (observed_at);

create table laundry.events (
  boot_id     uuid        not null references laundry.boots,
  event_seq   integer     not null check (event_seq >= 0),
  received_at timestamptz not null,
  observed_at timestamptz not null,
  type        smallint    not null references laundry.event_codes,
  machine     smallint    check (machine between 1 and 9),
  module_id   integer     check (module_id between 0 and 16777215),   -- private; never in a view
  real_load   boolean     not null,                -- washer_free after a real load, not a door bump
  primary key (boot_id, event_seq)
);
create index on laundry.events (observed_at desc);

-- Bronze: the 2026-11-09 laundry-room capture exactly as recorded (seed only).
create table laundry.raw_adverts (
  t         timestamptz not null,
  module_id integer     not null,
  rssi      smallint,
  b7        smallint,
  raw       bytea       not null,
  primary key (t, module_id, raw)
);

-- Gold: small, precomputed tables the public views read. Kept forever.
create table laundry.usage_hourly (
  hour           timestamptz not null,
  machine        smallint    not null,
  n_free         integer     not null,
  n_in_use       integer     not null,
  n_out_of_order integer     not null,
  n_unknown      integer     not null,
  primary key (hour, machine)
);

create table laundry.liveness_hourly (
  hour         timestamptz primary key,
  snapshots    integer not null,
  boots        integer not null,
  max_dropped  integer not null,
  max_rejected integer not null,
  max_skipped  integer not null
);

-- Web Push: one-shot subscriptions. The endpoint must belong to a real browser push service,
-- so the push function can never be pointed at an arbitrary URL.
create table laundry.push_subscriptions (
  endpoint   text primary key check (
               length(endpoint) <= 1024 and endpoint ~ ('^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com'
               || '|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/')),
  p256dh     text not null check (p256dh ~ '^[A-Za-z0-9_-]{80,100}$'),
  auth       text not null check (auth ~ '^[A-Za-z0-9_-]{16,32}$'),
  machine    smallint check (machine between 1 and 6),   -- null = any washer
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- Quotas and abuse visibility. One row per (time bucket, kind), never one row per call, so the
-- counters themselves cannot be used to fill the database.
create table laundry.call_counters (
  bucket timestamptz not null,
  kind   text        not null,
  n      integer     not null,
  primary key (bucket, kind)
);

------------------------------------------------------------------------------------------------
-- 3. Validation helpers. They raise 22023 (invalid_parameter_value) so callers can tell
--    "bad input" (dead-letter it) apart from "something broke" (retry).
------------------------------------------------------------------------------------------------
create function laundry.int_of(v jsonb, what text, lo bigint, hi bigint, nullable boolean default false)
returns bigint language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if nullable then return null; end if;
    raise exception 'missing %', what using errcode = '22023';
  end if;
  if jsonb_typeof(v) <> 'number' then
    raise exception '% is not a number', what using errcode = '22023';
  end if;
  n := (v #>> '{}')::numeric;
  if n <> trunc(n) or n < lo or n > hi then
    raise exception '% out of range', what using errcode = '22023';
  end if;
  return n::bigint;
end $$;

create function laundry.only_keys(j jsonb, allowed text[], what text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(j) <> 'object' then
    raise exception '% is not an object', what using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(j) k where k <> all (allowed)) then
    raise exception 'unknown key in %', what using errcode = '22023';
  end if;
end $$;

create function laundry.bump(p_kind text, p_bucket timestamptz default date_trunc('hour', now()))
returns integer language sql set search_path = '' as $$
  insert into laundry.call_counters as c (bucket, kind, n) values (p_bucket, p_kind, 1)
  on conflict (bucket, kind) do update set n = c.n + 1
  returning n;
$$;

------------------------------------------------------------------------------------------------
-- 4. store_batch: the one normalize-and-store path, shared by the live board (via ingest) and
--    the historical seed (called directly with the capture's own clock). All or nothing: any
--    invalid row raises and the whole batch rolls back.
--
-- Batch: {"v":1, "boot":"<32 hex>", "rows":[ row, ... ]}            (1-100 rows)
-- Snapshot row: {"k":"s","seq":n,"age":ms,"l":listener,"lr":dBm|null,"ok":n,"lost":n,
--                "heap":KB,"blk":KB,"drop":n,"rej":n,"skip":n,
--                "m":[[machine,state,since_s|null,rssi|null,since_restart 0/1] x 6]}
-- Event row:    {"k":"e","seq":n,"age":ms,"t":type,"n":machine|null,"mod":id|null,"real":0/1}
------------------------------------------------------------------------------------------------
create function laundry.store_batch(p jsonb, p_received timestamptz, p_device smallint)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_boot uuid;
  r jsonb; m jsonb; obs timestamptz; v_seq bigint; i int; n int;
  s_new int := 0; s_dup int := 0; e_new int := 0; e_dup int := 0;
begin
  perform laundry.only_keys(p, array['v', 'boot', 'rows'], 'batch');
  perform laundry.int_of(p -> 'v', 'v', 1, 1);
  if jsonb_typeof(p -> 'boot') is distinct from 'string' or (p ->> 'boot') !~ '^[0-9a-f]{32}$' then
    raise exception 'boot must be 32 hex characters' using errcode = '22023';
  end if;
  v_boot := (p ->> 'boot')::uuid;
  if jsonb_typeof(p -> 'rows') is distinct from 'array' or jsonb_array_length(p -> 'rows') not between 1 and 100 then
    raise exception 'rows must be an array of 1-100' using errcode = '22023';
  end if;

  insert into laundry.boots (boot_id, device_id, first_received) values (v_boot, p_device, p_received)
  on conflict (boot_id) do nothing;
  if (select device_id from laundry.boots where boot_id = v_boot) <> p_device then
    raise exception 'boot belongs to another device' using errcode = '22023';
  end if;

  for r in select value from jsonb_array_elements(p -> 'rows') loop
    if jsonb_typeof(r) <> 'object' then
      raise exception 'row is not an object' using errcode = '22023';
    end if;
    obs := p_received - make_interval(secs => laundry.int_of(r -> 'age', 'age', 0, 86400000) / 1000.0);
    v_seq := laundry.int_of(r -> 'seq', 'seq', 0, 2147483647);

    if r ->> 'k' = 's' then
      perform laundry.only_keys(r, array['k','seq','age','l','lr','ok','lost','heap','blk','drop','rej','skip','m'], 'snapshot');
      insert into laundry.snapshots
        (boot_id, seq, received_at, observed_at, listener, link_rssi, frames_ok, frames_lost,
         heap_kb, block_kb, dropped, rejected, skipped)
      values
        (v_boot, v_seq, p_received, obs,
         laundry.int_of(r -> 'l', 'l', 0, 3),
         laundry.int_of(r -> 'lr', 'lr', -127, 0, true),
         laundry.int_of(r -> 'ok', 'ok', 0, 4294967295),
         laundry.int_of(r -> 'lost', 'lost', 0, 4294967295),
         laundry.int_of(r -> 'heap', 'heap', 0, 32767),
         laundry.int_of(r -> 'blk', 'blk', 0, 32767),
         laundry.int_of(r -> 'drop', 'drop', 0, 2147483647),
         laundry.int_of(r -> 'rej', 'rej', 0, 2147483647),
         laundry.int_of(r -> 'skip', 'skip', 0, 2147483647))
      on conflict (boot_id, seq) do nothing;
      get diagnostics n = row_count;
      if n = 1 then s_new := s_new + 1; else s_dup := s_dup + 1; end if;

      if jsonb_typeof(r -> 'm') is distinct from 'array' or jsonb_array_length(r -> 'm') <> 6 then
        raise exception 'm must list 6 washers' using errcode = '22023';
      end if;
      for i in 0..5 loop
        m := r -> 'm' -> i;
        if jsonb_typeof(m) is distinct from 'array' or jsonb_array_length(m) <> 5 then
          raise exception 'washer entry must have 5 values' using errcode = '22023';
        end if;
        if laundry.int_of(m -> 0, 'machine', 1, 6) <> i + 1 then
          raise exception 'washers must be listed 1-6 in order' using errcode = '22023';
        end if;
        insert into laundry.machine_readings
          (boot_id, seq, machine, observed_at, state, state_since, since_restart, rssi)
        values
          (v_boot, v_seq, i + 1, obs,
           laundry.int_of(m -> 1, 'state', 0, 5),
           obs - make_interval(secs => laundry.int_of(m -> 2, 'since_s', 0, 31536000, true)),
           laundry.int_of(m -> 4, 'since_restart', 0, 1) = 1,
           laundry.int_of(m -> 3, 'rssi', -127, 0, true))
        on conflict (boot_id, seq, machine) do nothing;
      end loop;

    elsif r ->> 'k' = 'e' then
      perform laundry.only_keys(r, array['k','seq','age','t','n','mod','real'], 'event');
      insert into laundry.events (boot_id, event_seq, received_at, observed_at, type, machine, module_id, real_load)
      values
        (v_boot, v_seq, p_received, obs,
         laundry.int_of(r -> 't', 't', 0, 8),
         laundry.int_of(r -> 'n', 'n', 1, 9, true),
         laundry.int_of(r -> 'mod', 'mod', 0, 16777215, true),
         laundry.int_of(r -> 'real', 'real', 0, 1) = 1)
      on conflict (boot_id, event_seq) do nothing;
      get diagnostics n = row_count;
      if n = 1 then e_new := e_new + 1; else e_dup := e_dup + 1; end if;

    else
      raise exception 'row kind must be s or e' using errcode = '22023';
    end if;
  end loop;

  return jsonb_build_object('snapshots', s_new, 'snapshot_dups', s_dup, 'events', e_new, 'event_dups', e_dup);
end $$;

------------------------------------------------------------------------------------------------
-- 5. public.ingest: the only way the board writes. HTTP status codes tell the board what to do:
--    200 stored (ack) · 400/401/413 permanent (dead-letter) · 429 slow down (retry later)
--    · 5xx anything unexpected (retry). Refusals are counted and committed, the batch is not.
------------------------------------------------------------------------------------------------
create function public.ingest(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  tok text := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-device-token', '');
  dev smallint;
  res jsonb;
begin
  if length(tok) >= 32 then
    select id into dev from laundry.devices
    where token_sha256 = extensions.digest(tok, 'sha256') and id <> 0;
  end if;
  if dev is null then
    perform laundry.bump('ingest_reject_token');
    perform set_config('response.status', '401', true);
    return jsonb_build_object('error', 'bad token');
  end if;

  if octet_length(p::text) > 32768 then
    perform laundry.bump('ingest_reject_size');
    perform set_config('response.status', '413', true);
    return jsonb_build_object('error', 'batch too large');
  end if;

  -- Quotas: normal is 1-3 calls a minute and one new boot per power-up.
  if laundry.bump('ingest_call', date_trunc('minute', now())) > 10
     or (jsonb_typeof(p -> 'boot') = 'string' and (p ->> 'boot') ~ '^[0-9a-f]{32}$'
         and not exists (select 1 from laundry.boots where boot_id = (p ->> 'boot')::uuid)
         and (select count(*) from laundry.boots
              where device_id = dev and first_received > now() - interval '1 hour') >= 3) then
    perform laundry.bump('ingest_reject_quota');
    perform set_config('response.status', '429', true);
    perform set_config('response.headers', '[{"Retry-After": "60"}]', true);
    return jsonb_build_object('error', 'over quota');
  end if;

  begin
    res := laundry.store_batch(p, now(), dev);
  exception when data_exception or integrity_constraint_violation then
    perform laundry.bump('ingest_reject_shape');
    perform set_config('response.status', '400', true);
    return jsonb_build_object('error', 'rejected', 'reason', left(sqlerrm, 120));
  end;
  perform laundry.bump('ingest_ok');
  return res;
end $$;

------------------------------------------------------------------------------------------------
-- 6. public.subscribe_push: the page saves a browser push subscription for one alert.
--    Body is PushSubscription.toJSON() plus an optional machine number.
------------------------------------------------------------------------------------------------
create function public.subscribe_push(sub jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_machine smallint;
begin
  if laundry.bump('subscribe_call', date_trunc('minute', now())) > 30 then
    perform laundry.bump('subscribe_reject_quota');
    perform set_config('response.status', '429', true);
    return jsonb_build_object('error', 'busy, try again in a minute');
  end if;
  begin
    perform laundry.only_keys(sub, array['endpoint', 'expirationTime', 'keys', 'machine'], 'subscription');
    perform laundry.only_keys(sub -> 'keys', array['p256dh', 'auth'], 'keys');
    v_machine := laundry.int_of(sub -> 'machine', 'machine', 1, 6, true);
    if not exists (select 1 from laundry.push_subscriptions where endpoint = sub ->> 'endpoint')
       and (select count(*) from laundry.push_subscriptions where expires_at > now()) >= 500 then
      perform laundry.bump('subscribe_reject_full');
      perform set_config('response.status', '429', true);
      return jsonb_build_object('error', 'too many alerts waiting');
    end if;
    insert into laundry.push_subscriptions (endpoint, p256dh, auth, machine, expires_at)
    values (sub ->> 'endpoint', sub -> 'keys' ->> 'p256dh', sub -> 'keys' ->> 'auth', v_machine,
            now() + interval '3 hours')
    on conflict (endpoint) do update
      set p256dh = excluded.p256dh, auth = excluded.auth, machine = excluded.machine,
          created_at = now(), expires_at = excluded.expires_at;
  exception when data_exception or integrity_constraint_violation then
    perform laundry.bump('subscribe_reject_shape');
    perform set_config('response.status', '400', true);
    return jsonb_build_object('error', 'invalid subscription');
  end;
  perform laundry.bump('subscribe_ok');
  return jsonb_build_object('ok', true, 'expires_in_minutes', 180);
end $$;

------------------------------------------------------------------------------------------------
-- 7. Public read views. Each reads a bounded slice (newest row by index, last 24 h, or the small
--    gold tables), never a full scan of readings. They run as their owner, which is what lets
--    them read the private schema; anon gets SELECT on the views only.
------------------------------------------------------------------------------------------------
create view public.scanner_status as
select s.observed_at as last_snapshot_at,
       now() - s.observed_at > interval '3 minutes' as stale,
       lc.name as listener
from (select observed_at, listener from laundry.snapshots order by observed_at desc limit 1) s
join laundry.listener_codes lc on lc.code = s.listener;

create view public.machine_status as
select r.machine, sc.name as state, r.state_since, r.since_restart, s.observed_at as as_of
from (select boot_id, seq, observed_at from laundry.snapshots
      where observed_at > now() - interval '10 minutes'
      order by observed_at desc limit 1) s
join laundry.machine_readings r on r.boot_id = s.boot_id and r.seq = s.seq
join laundry.state_codes sc on sc.code = r.state;

create view public.recent_events as
select date_trunc('minute', e.observed_at) as at, ec.name as event, e.machine
from laundry.events e
join laundry.event_codes ec on ec.code = e.type
where e.observed_at > now() - interval '24 hours'
  and e.type in (0, 1, 5, 6)                         -- washer free/taken, scanner lost/back
  and (e.machine is null or e.machine between 1 and 6)
order by e.observed_at desc
limit 50;

-- Typical week: % of known washer-minutes in use, by local weekday and hour (last 12 weeks).
create view public.usage_by_hour as
select extract(isodow from u.hour at time zone 'America/Denver')::int as dow,
       extract(hour   from u.hour at time zone 'America/Denver')::int as hour_of_day,
       round(100.0 * sum(u.n_in_use) / nullif(sum(u.n_free + u.n_in_use), 0), 1) as pct_in_use,
       count(distinct (u.hour at time zone 'America/Denver')::date) as days
from laundry.usage_hourly u
where u.hour > now() - interval '12 weeks'
group by 1, 2;

-- The last 48 hours, hour by hour, to lay over the typical week ("today vs typical").
create view public.usage_recent as
select u.hour,
       round(100.0 * sum(u.n_in_use) / nullif(sum(u.n_free + u.n_in_use), 0), 1) as pct_in_use
from laundry.usage_hourly u
where u.hour > now() - interval '48 hours'
group by u.hour;

create view public.liveness_hourly as
select hour, snapshots, boots, max_dropped, max_rejected, max_skipped
from laundry.liveness_hourly
where hour > now() - interval '7 days';

------------------------------------------------------------------------------------------------
-- 8. Jobs (pg_cron): rollup every 5 min, nightly retention, DB-write watchdog every 5 min.
------------------------------------------------------------------------------------------------
-- Recomputes whole hours in [p_from, p_to), so readings that arrive late (outbox backfill) are
-- counted the next time it runs. Upsert, so running it twice changes nothing.
create function laundry.rollup(p_from timestamptz, p_to timestamptz)
returns void language sql set search_path = '' as $$
  insert into laundry.usage_hourly as u (hour, machine, n_free, n_in_use, n_out_of_order, n_unknown)
  select date_trunc('hour', observed_at), machine,
         count(*) filter (where state = 0), count(*) filter (where state = 1),
         count(*) filter (where state = 2), count(*) filter (where state >= 3)
  from laundry.machine_readings
  where observed_at >= date_trunc('hour', p_from) and observed_at < p_to
  group by 1, 2
  on conflict (hour, machine) do update
    set n_free = excluded.n_free, n_in_use = excluded.n_in_use,
        n_out_of_order = excluded.n_out_of_order, n_unknown = excluded.n_unknown;

  insert into laundry.liveness_hourly as l (hour, snapshots, boots, max_dropped, max_rejected, max_skipped)
  select date_trunc('hour', observed_at), count(*), count(distinct boot_id),
         max(dropped), max(rejected), max(skipped)
  from laundry.snapshots
  where observed_at >= date_trunc('hour', p_from) and observed_at < p_to
  group by 1
  on conflict (hour) do update
    set snapshots = excluded.snapshots, boots = excluded.boots, max_dropped = excluded.max_dropped,
        max_rejected = excluded.max_rejected, max_skipped = excluded.max_skipped;
$$;

-- Keeps 90 days of minute-level detail; the hourly gold tables stay forever. The seed (device 0)
-- is never deleted.
create function laundry.retention()
returns void language sql set search_path = '' as $$
  delete from laundry.snapshots s using laundry.boots b
   where b.boot_id = s.boot_id and b.device_id <> 0 and s.observed_at < now() - interval '90 days';
  delete from laundry.events e using laundry.boots b
   where b.boot_id = e.boot_id and b.device_id <> 0 and e.observed_at < now() - interval '90 days';
  delete from laundry.call_counters where bucket < now() - interval '30 days';
  delete from laundry.push_subscriptions where expires_at < now();
$$;

-- Pings the second healthchecks check only while everything is healthy, so silence = trouble:
-- a fresh snapshot arrived, the DB is under 300 MB, and refusals are not spiking.
create function laundry.watchdog()
returns void language plpgsql set search_path = '' as $$
declare v_url text;
begin
  if exists (select 1 from laundry.snapshots where received_at > now() - interval '5 minutes')
     and pg_database_size(current_database()) < 300 * 1024 * 1024
     and coalesce((select sum(n) from laundry.call_counters
                   where kind like '%reject%' and bucket >= date_trunc('hour', now()) - interval '1 hour'), 0) < 100
  then
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'hc_db_ping_url';
    if v_url is not null then
      perform net.http_get(url := v_url);   -- read from Vault at run time, never stored in the job
    end if;
  end if;
end $$;

select cron.schedule('laundry-rollup',    '*/5 * * * *', $$select laundry.rollup(now() - interval '3 hours', now())$$);
select cron.schedule('laundry-retention', '17 9 * * *',  $$select laundry.retention()$$);   -- ~2-3 AM Denver
select cron.schedule('laundry-watchdog',  '*/5 * * * *', $$select laundry.watchdog()$$);

------------------------------------------------------------------------------------------------
-- 9. Grants: the complete public surface. security_test.py checks it is exactly this.
------------------------------------------------------------------------------------------------
revoke all on all tables    in schema laundry from public, anon, authenticated;
revoke all on all functions in schema laundry from public, anon, authenticated;

revoke all on public.scanner_status, public.machine_status, public.recent_events,
              public.usage_by_hour, public.usage_recent, public.liveness_hourly
  from public, anon, authenticated;
grant select on public.scanner_status, public.machine_status, public.recent_events,
                public.usage_by_hour, public.usage_recent, public.liveness_hourly
  to anon;

revoke all on function public.ingest(jsonb), public.subscribe_push(jsonb) from public, anon, authenticated;
grant execute on function public.ingest(jsonb), public.subscribe_push(jsonb) to anon;
