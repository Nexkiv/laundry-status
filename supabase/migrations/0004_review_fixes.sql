-- Fixes from the implementation review (2026-11-12). Every function here is a create or replace of
-- one from 0001/0003 or a new private helper; the public surface shrinks by three views.
--
--   devices     the two device rows the rest of the schema assumes (no-op where they exist)
--   store_batch split into per-row helpers; washers validated before anything is inserted; code
--               columns range-checked loosely so the code tables alone decide what is valid
--   ingest      quota steps named and ordered; the boot format lives in one helper
--   subscribe   per-client rate limit and active-alert cap, so one client can't lock everyone out
--   notify_free a failing alert can no longer roll back the batch that fired it; a missing secret
--               keeps the subscriptions; every push request is recorded for the watchdog
--   watchdog    also goes silent when alerts are failing
--   views       usage_by_hour, usage_recent, liveness_hourly dropped (nothing reads them)

------------------------------------------------------------------------------------------------
-- Devices. Device 0 is the historical seed (its random hash can never match a token); device 1 is
-- the base board, whose real hash is set by hand (docs/runbook.md, "Rotate the device token").
------------------------------------------------------------------------------------------------
insert into laundry.devices (id, name, token_sha256) values
  (0, 'seed', extensions.gen_random_bytes(32)),
  (1, 'base', extensions.gen_random_bytes(32))
on conflict (id) do nothing;

------------------------------------------------------------------------------------------------
-- store_batch and its helpers
------------------------------------------------------------------------------------------------
-- The batch's boot id as a uuid, or null when it isn't 32 lowercase hex characters.
create function laundry.boot_of(p jsonb)
returns uuid language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p -> 'boot') = 'string' and (p ->> 'boot') ~ '^[0-9a-f]{32}$'
              then (p ->> 'boot')::uuid end;
$$;

-- Code columns (listener, state, event type) only need to be small non-negative integers here;
-- their foreign keys reject unknown codes, and ingest maps that to 400 like any other bad input.
create function laundry.store_snapshot_row(p_boot uuid, r jsonb, p_received timestamptz)
returns boolean language plpgsql set search_path = '' as $$
declare
  obs timestamptz;
  v_seq bigint;
  m jsonb;
  i int;
  n int;
  st smallint[] := '{}'; since timestamptz[] := '{}'; restart boolean[] := '{}'; rs smallint[] := '{}';
begin
  perform laundry.only_keys(r, array['k','seq','age','l','lr','ok','lost','heap','blk','drop','rej','skip','m'], 'snapshot');
  obs := p_received - make_interval(secs => laundry.int_of(r -> 'age', 'age', 0, 86400000) / 1000.0);
  v_seq := laundry.int_of(r -> 'seq', 'seq', 0, 2147483647);

  -- All six washers are checked before anything is written.
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
    st      := st      || laundry.int_of(m -> 1, 'state', 0, 32767)::smallint;
    since   := since   || (obs - make_interval(secs => laundry.int_of(m -> 2, 'since_s', 0, 31536000, true)));
    restart := restart || (laundry.int_of(m -> 4, 'since_restart', 0, 1) = 1);
    rs      := rs      || laundry.int_of(m -> 3, 'rssi', -127, 0, true)::smallint;
  end loop;

  insert into laundry.snapshots
    (boot_id, seq, received_at, observed_at, listener, link_rssi, frames_ok, frames_lost,
     heap_kb, block_kb, dropped, rejected, skipped)
  values
    (p_boot, v_seq, p_received, obs,
     laundry.int_of(r -> 'l', 'l', 0, 32767),
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

  insert into laundry.machine_readings
    (boot_id, seq, machine, observed_at, state, state_since, since_restart, rssi)
  select p_boot, v_seq, k, obs, st[k], since[k], restart[k], rs[k]
  from generate_series(1, 6) k
  on conflict (boot_id, seq, machine) do nothing;

  return n = 1;
end $$;

create function laundry.store_event_row(p_boot uuid, r jsonb, p_received timestamptz)
returns boolean language plpgsql set search_path = '' as $$
declare n int;
begin
  perform laundry.only_keys(r, array['k','seq','age','t','n','mod','real'], 'event');
  insert into laundry.events (boot_id, event_seq, received_at, observed_at, type, machine, module_id, real_load)
  values
    (p_boot,
     laundry.int_of(r -> 'seq', 'seq', 0, 2147483647),
     p_received,
     p_received - make_interval(secs => laundry.int_of(r -> 'age', 'age', 0, 86400000) / 1000.0),
     laundry.int_of(r -> 't', 't', 0, 32767),
     laundry.int_of(r -> 'n', 'n', 1, 9, true),
     laundry.int_of(r -> 'mod', 'mod', 0, 16777215, true),
     laundry.int_of(r -> 'real', 'real', 0, 1) = 1)
  on conflict (boot_id, event_seq) do nothing;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- The one normalize-and-store path, shared by the live board (via ingest) and the historical seed.
-- All or nothing: any invalid row raises and the whole batch rolls back. Format: see 0001 §4.
create or replace function laundry.store_batch(p jsonb, p_received timestamptz, p_device smallint)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_boot uuid;
  r jsonb;
  s_new int := 0; s_dup int := 0; e_new int := 0; e_dup int := 0;
begin
  perform laundry.only_keys(p, array['v', 'boot', 'rows'], 'batch');
  perform laundry.int_of(p -> 'v', 'v', 1, 1);
  v_boot := laundry.boot_of(p);
  if v_boot is null then
    raise exception 'boot must be 32 hex characters' using errcode = '22023';
  end if;
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
    if r ->> 'k' = 's' then
      if laundry.store_snapshot_row(v_boot, r, p_received) then s_new := s_new + 1; else s_dup := s_dup + 1; end if;
    elsif r ->> 'k' = 'e' then
      if laundry.store_event_row(v_boot, r, p_received) then e_new := e_new + 1; else e_dup := e_dup + 1; end if;
    else
      raise exception 'row kind must be s or e' using errcode = '22023';
    end if;
  end loop;

  return jsonb_build_object('snapshots', s_new, 'snapshot_dups', s_dup, 'events', e_new, 'event_dups', e_dup);
end $$;

------------------------------------------------------------------------------------------------
-- ingest: same checks and status codes as 0001, with the quota steps spelled out in order.
------------------------------------------------------------------------------------------------
create or replace function public.ingest(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  tok text := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-device-token', '');
  dev smallint;
  v_calls int;
  v_boot uuid;
  v_new_boot boolean;
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

  -- Quotas: normal is 1-3 calls a minute and one new boot per power-up. Every call is counted.
  v_calls := laundry.bump('ingest_call', date_trunc('minute', now()));
  v_boot := laundry.boot_of(p);
  v_new_boot := v_boot is not null and not exists (select 1 from laundry.boots where boot_id = v_boot);
  if v_calls > 10
     or (v_new_boot and (select count(*) from laundry.boots
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
-- subscribe_push: per-client limits. The client is a salted hash of its IP (never the IP itself);
-- the salt lives in Vault. Limits are per IP but generous (10 calls a minute, 20 active alerts),
-- because neighbors and phone carriers often share one IP. A client over its own limit is
-- refused before it touches the shared counter, so one client can't use up everyone's quota, and
-- those refusals aren't counted as rejects, so one client can't trip the DB watchdog either.
------------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'client_salt') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(16), 'hex'), 'client_salt',
                                'salt for hashing client IPs in subscribe_push');
  end if;
end $$;

alter table laundry.push_subscriptions add column client text;   -- salted IP hash; null = unknown
create index on laundry.push_subscriptions (client);

-- Salted hash of the caller's IP from the API gateway's headers, or null if there is none.
create function laundry.client_key()
returns text language plpgsql stable set search_path = '' as $$
declare
  h jsonb := coalesce(current_setting('request.headers', true), '{}')::jsonb;
  ip text := nullif(trim(coalesce(split_part(h ->> 'x-forwarded-for', ',', 1), h ->> 'cf-connecting-ip', '')), '');
  salt text;
begin
  if ip is null then return null; end if;
  select decrypted_secret into salt from vault.decrypted_secrets where name = 'client_salt';
  return encode(extensions.digest(coalesce(salt, '') || ip, 'sha256'), 'hex');
end $$;

create or replace function public.subscribe_push(sub jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ttl constant interval := interval '3 hours';
  v_min smallint;
  v_client text := laundry.client_key();
begin
  if v_client is not null then
    if laundry.bump('subscribe_client_' || left(v_client, 16), date_trunc('minute', now())) > 10 then
      perform laundry.bump('subscribe_client_limited');
      perform set_config('response.status', '429', true);
      return jsonb_build_object('error', 'busy, try again in a minute');
    end if;
  end if;
  if laundry.bump('subscribe_call', date_trunc('minute', now())) > 30 then
    perform laundry.bump('subscribe_reject_quota');
    perform set_config('response.status', '429', true);
    return jsonb_build_object('error', 'busy, try again in a minute');
  end if;
  begin
    perform laundry.only_keys(sub, array['endpoint', 'expirationTime', 'keys', 'min_free'], 'subscription');
    perform laundry.only_keys(sub -> 'keys', array['p256dh', 'auth'], 'keys');
    v_min := coalesce(laundry.int_of(sub -> 'min_free', 'min_free', 1, 6, true), 1);
    if not exists (select 1 from laundry.push_subscriptions where endpoint = sub ->> 'endpoint') then
      if v_client is not null and (select count(*) from laundry.push_subscriptions
                                   where client = v_client and expires_at > now()) >= 20 then
        perform laundry.bump('subscribe_client_limited');
        perform set_config('response.status', '429', true);
        return jsonb_build_object('error', 'too many alerts from this device');
      end if;
      if (select count(*) from laundry.push_subscriptions where expires_at > now()) >= 500 then
        perform laundry.bump('subscribe_reject_full');
        perform set_config('response.status', '429', true);
        return jsonb_build_object('error', 'too many alerts waiting');
      end if;
    end if;
    insert into laundry.push_subscriptions (endpoint, p256dh, auth, min_free, client, expires_at)
    values (sub ->> 'endpoint', sub -> 'keys' ->> 'p256dh', sub -> 'keys' ->> 'auth', v_min, v_client,
            now() + v_ttl)
    on conflict (endpoint) do update
      set p256dh = excluded.p256dh, auth = excluded.auth, min_free = excluded.min_free,
          client = excluded.client, created_at = now(), expires_at = excluded.expires_at;
  exception when data_exception or integrity_constraint_violation then
    perform laundry.bump('subscribe_reject_shape');
    perform set_config('response.status', '400', true);
    return jsonb_build_object('error', 'invalid subscription');
  end;
  perform laundry.bump('subscribe_ok');
  return jsonb_build_object('ok', true, 'min_free', v_min,
                            'expires_in_minutes', (extract(epoch from v_ttl) / 60)::int);
end $$;
revoke all on function public.subscribe_push(jsonb) from public, anon, authenticated;
grant execute on function public.subscribe_push(jsonb) to anon;

------------------------------------------------------------------------------------------------
-- notify_free: same rule as 0003. Changes: any error is counted as push_error instead of rolling
-- back the batch (the trigger runs at COMMIT, outside ingest's error handling); a missing hook
-- secret keeps the subscriptions; each request id is recorded so the watchdog can read the reply.
------------------------------------------------------------------------------------------------
create table laundry.push_requests (
  id         bigint primary key,                 -- net.http_post request id (net._http_response.id)
  created_at timestamptz not null default now()
);
revoke all on laundry.push_requests from public, anon, authenticated;

create or replace function laundry.notify_free()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_snap record;
  v_free int;
  v_still_free boolean;
  v_subs jsonb;
  v_secret text;
  v_req bigint;
begin
  if new.type <> 0 or not new.real_load or new.observed_at < now() - interval '2 minutes' then
    return null;
  end if;
  begin
    select s.boot_id, s.seq into v_snap from laundry.snapshots s order by s.observed_at desc limit 1;
    select count(*) filter (where r.state = 0), bool_or(r.machine = new.machine and r.state = 0)
      into v_free, v_still_free
      from laundry.machine_readings r where r.boot_id = v_snap.boot_id and r.seq = v_snap.seq;
    if not coalesce(v_still_free, false) then
      return null;
    end if;

    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_hook_secret';
    if v_secret is null then
      perform laundry.bump('push_no_secret');
      return null;
    end if;

    with sent as (
      delete from laundry.push_subscriptions
       where expires_at > now() and min_free <= v_free
      returning endpoint, p256dh, auth)
    select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'keys', jsonb_build_object('p256dh', p256dh, 'auth', auth)))
      into v_subs from sent;
    if v_subs is null then
      return null;
    end if;

    v_req := net.http_post(
      url := 'https://gcxxytnkouvllfioqqlv.supabase.co/functions/v1/push',
      body := jsonb_build_object('free', v_free, 'subscriptions', v_subs),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_secret),
      timeout_milliseconds := 10000);
    insert into laundry.push_requests (id) values (v_req);
    perform laundry.bump('push_sent');
  exception when others then
    perform laundry.bump('push_error');   -- the alert is lost (subscriptions kept); the batch is not
  end;
  return null;
end $$;
revoke all on function laundry.notify_free() from public, anon, authenticated;

------------------------------------------------------------------------------------------------
-- watchdog: also silent when alerts are failing (a push call answered non-2xx or timed out, a
-- trigger error, or a missing hook secret in the last hour).
------------------------------------------------------------------------------------------------
create or replace function laundry.watchdog()
returns void language plpgsql set search_path = '' as $$
declare v_url text;
begin
  if exists (select 1 from laundry.snapshots where received_at > now() - interval '5 minutes')
     and pg_database_size(current_database()) < 300 * 1024 * 1024
     and coalesce((select sum(n) from laundry.call_counters
                   where kind like '%reject%' and bucket >= date_trunc('hour', now()) - interval '1 hour'), 0) < 100
     and not exists (select 1 from laundry.call_counters
                     where kind in ('push_error', 'push_no_secret') and bucket >= date_trunc('hour', now()) - interval '1 hour')
     and not exists (select 1 from laundry.push_requests q join net._http_response r on r.id = q.id
                     where q.created_at > now() - interval '1 hour'
                       and (r.timed_out or r.status_code is null or r.status_code not between 200 and 299))
  then
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'hc_db_ping_url';
    if v_url is not null then
      perform net.http_get(url := v_url);   -- read from Vault at run time, never stored in the job
    end if;
  end if;
end $$;

create or replace function laundry.retention()
returns void language sql set search_path = '' as $$
  delete from laundry.snapshots s using laundry.boots b
   where b.boot_id = s.boot_id and b.device_id <> 0 and s.observed_at < now() - interval '90 days';
  delete from laundry.events e using laundry.boots b
   where b.boot_id = e.boot_id and b.device_id <> 0 and e.observed_at < now() - interval '90 days';
  delete from laundry.call_counters where bucket < now() - interval '30 days';
  delete from laundry.push_subscriptions where expires_at < now();
  delete from laundry.push_requests where created_at < now() - interval '30 days';
$$;

------------------------------------------------------------------------------------------------
-- Unused public views (the page reads scanner_status, machine_status and recent_events only).
-- sql/4_today_vs_typical.sql reads laundry.usage_hourly directly.
------------------------------------------------------------------------------------------------
drop view public.usage_by_hour, public.usage_recent, public.liveness_hourly;

revoke all on function laundry.boot_of(jsonb), laundry.client_key(),
                       laundry.store_snapshot_row(uuid, jsonb, timestamptz),
                       laundry.store_event_row(uuid, jsonb, timestamptz)
  from public, anon, authenticated;
