-- Idempotency: every table's natural key is unique, so total rows = distinct keys.
-- Every write is insert ... on conflict do nothing on these keys; a retried batch or a
-- re-run seed adds nothing (see 3b_replay.sql for a live demonstration).
select 'snapshots' as table_name, count(*) as total,
       count(distinct (boot_id, seq)) as distinct_keys from laundry.snapshots
union all
select 'machine_readings', count(*), count(distinct (boot_id, seq, machine)) from laundry.machine_readings
union all
select 'events', count(*), count(distinct (boot_id, event_seq)) from laundry.events
union all
select 'raw_adverts', count(*), count(distinct (t, module_id, raw)) from laundry.raw_adverts
union all
select 'usage_hourly', count(*), count(distinct (hour, machine)) from laundry.usage_hourly;
