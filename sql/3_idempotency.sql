-- Idempotency: every table's natural key is unique, so total rows = distinct keys.
-- Raw and per-minute rows are written with insert ... on conflict do nothing on these keys, so a
-- retried batch or a re-run seed adds nothing (3b_replay.sql shows it live). The hourly gold table
-- is an upsert on its key, so recomputing an hour replaces it instead of adding a row.
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
