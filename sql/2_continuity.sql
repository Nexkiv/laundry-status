-- Continuity: every stretch of more than 3 minutes with no snapshot, and why.
-- The board snapshots every 60 s and its outbox backfills short outages, so a gap means one of:
-- the seed/live boundary, a board restart (new boot_id), or rows the outbox had to drop.
with s as (
  select b.device_id, s.boot_id, s.observed_at, s.dropped,
         lag(s.observed_at) over w as prev_at,
         lag(s.boot_id)     over w as prev_boot,
         lag(b.device_id)   over w as prev_device,
         lag(s.dropped)     over w as prev_dropped
  from laundry.snapshots s
  join laundry.boots b using (boot_id)
  window w as (order by s.observed_at)
)
select prev_at     at time zone 'America/Denver' as gap_from,
       observed_at at time zone 'America/Denver' as gap_to,
       date_trunc('second', observed_at - prev_at) as length,
       case
         when device_id <> prev_device then 'seed capture ended; live pipeline started (push-only source, not backfillable)'
         when boot_id <> prev_boot     then 'board restarted (new boot_id)'
         when dropped > prev_dropped   then format('outbox full: %s rows dropped', dropped - prev_dropped)
         else 'unexplained'
       end as reason
from s
where observed_at - prev_at > interval '3 minutes'
order by gap_from;
