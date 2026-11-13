-- Liveness: is the live pipeline writing right now? One row.
-- Expect: last write under ~1 min ago, ~60 snapshots in the last hour, listener online,
-- frames lost about 1%, largest heap block above the 45 KB guard, no drops / dead letters / skips.
select now() - s.received_at                                            as last_write_ago,
       (select count(*) from laundry.snapshots x join laundry.boots xb using (boot_id)
         where xb.device_id = 1 and x.received_at > now() - interval '1 hour') as snapshots_last_hour,
       l.name                                                           as listener,
       round(100.0 * s.frames_lost / nullif(s.frames_ok + s.frames_lost, 0), 1) as pct_frames_lost,
       s.heap_kb, s.block_kb,
       s.dropped as outbox_dropped, s.rejected as dead_letters, s.skipped as heap_guard_skips,
       b.first_received at time zone 'America/Denver'                   as board_up_since
from laundry.snapshots s
join laundry.boots b using (boot_id)
join laundry.listener_codes l on l.code = s.listener
where b.device_id = 1                       -- the base board (device 0 is the historical seed)
order by s.received_at desc
limit 1;
