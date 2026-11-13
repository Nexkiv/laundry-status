-- Web Push by free-washer count: "tell me once when at least N washers are free".
-- (Replaces the per-machine option from 0001: people doing several loads need several washers.)

alter table laundry.push_subscriptions drop column machine;
alter table laundry.push_subscriptions add column min_free smallint not null default 1 check (min_free between 1 and 6);

create or replace function public.subscribe_push(sub jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_min smallint;
begin
  if laundry.bump('subscribe_call', date_trunc('minute', now())) > 30 then
    perform laundry.bump('subscribe_reject_quota');
    perform set_config('response.status', '429', true);
    return jsonb_build_object('error', 'busy, try again in a minute');
  end if;
  begin
    perform laundry.only_keys(sub, array['endpoint', 'expirationTime', 'keys', 'min_free'], 'subscription');
    perform laundry.only_keys(sub -> 'keys', array['p256dh', 'auth'], 'keys');
    v_min := coalesce(laundry.int_of(sub -> 'min_free', 'min_free', 1, 6, true), 1);
    if not exists (select 1 from laundry.push_subscriptions where endpoint = sub ->> 'endpoint')
       and (select count(*) from laundry.push_subscriptions where expires_at > now()) >= 500 then
      perform laundry.bump('subscribe_reject_full');
      perform set_config('response.status', '429', true);
      return jsonb_build_object('error', 'too many alerts waiting');
    end if;
    insert into laundry.push_subscriptions (endpoint, p256dh, auth, min_free, expires_at)
    values (sub ->> 'endpoint', sub -> 'keys' ->> 'p256dh', sub -> 'keys' ->> 'auth', v_min,
            now() + interval '3 hours')
    on conflict (endpoint) do update
      set p256dh = excluded.p256dh, auth = excluded.auth, min_free = excluded.min_free,
          created_at = now(), expires_at = excluded.expires_at;
  exception when data_exception or integrity_constraint_violation then
    perform laundry.bump('subscribe_reject_shape');
    perform set_config('response.status', '400', true);
    return jsonb_build_object('error', 'invalid subscription');
  end;
  perform laundry.bump('subscribe_ok');
  return jsonb_build_object('ok', true, 'min_free', v_min, 'expires_in_minutes', 180);
end $$;
revoke all on function public.subscribe_push(jsonb) from public, anon, authenticated;
grant execute on function public.subscribe_push(jsonb) to anon;

-- Runs at COMMIT (deferred), after the whole batch is stored: the board sends the "washer freed"
-- event before the fresh snapshot in the same batch, so an immediate trigger would count free
-- washers from the previous snapshot and always be one short.
--
-- Sends only when all hold: a real load just ended (not a door bump), it was observed in the last
-- 2 minutes (no alerts from an outbox backlog or the historical seed), and the washer is still free
-- in the newest snapshot. Matching subscriptions are handed to the Edge Function and deleted here,
-- in the same transaction: each alert is sent once.
create function laundry.notify_free()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_snap record;
  v_free int;
  v_still_free boolean;
  v_subs jsonb;
  v_secret text;
begin
  if new.type <> 0 or not new.real_load or new.observed_at < now() - interval '2 minutes' then
    return null;
  end if;
  select s.boot_id, s.seq into v_snap from laundry.snapshots s order by s.observed_at desc limit 1;
  select count(*) filter (where r.state = 0), bool_or(r.machine = new.machine and r.state = 0)
    into v_free, v_still_free
    from laundry.machine_readings r where r.boot_id = v_snap.boot_id and r.seq = v_snap.seq;
  if not coalesce(v_still_free, false) then
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

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_hook_secret';
  perform net.http_post(
    url := 'https://gcxxytnkouvllfioqqlv.supabase.co/functions/v1/push',
    body := jsonb_build_object('free', v_free, 'subscriptions', v_subs),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_secret),
    timeout_milliseconds := 10000);
  perform laundry.bump('push_sent', date_trunc('hour', now()));
  return null;
end $$;
revoke all on function laundry.notify_free() from public, anon, authenticated;

create constraint trigger notify_free
  after insert on laundry.events
  deferrable initially deferred
  for each row execute function laundry.notify_free();
