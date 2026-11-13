-- Replay: rebuild the newest stored snapshot as the board's own JSON and store it again through
-- the same function ingest() uses. Expect snapshots 0, snapshot_dups 1: nothing is added.
with newest as (
  select s.* from laundry.snapshots s join laundry.boots b using (boot_id)
  where b.device_id = 1 order by s.observed_at desc limit 1
)
select laundry.store_batch(
         jsonb_build_object('v', 1, 'boot', replace(n.boot_id::text, '-', ''), 'rows', jsonb_build_array(
           jsonb_build_object('k', 's', 'seq', n.seq, 'age', 0, 'l', n.listener, 'lr', n.link_rssi,
             'ok', n.frames_ok, 'lost', n.frames_lost, 'heap', n.heap_kb, 'blk', n.block_kb,
             'drop', n.dropped, 'rej', n.rejected, 'skip', n.skipped,
             'm', (select jsonb_agg(jsonb_build_array(r.machine, r.state,
                                     extract(epoch from r.observed_at - r.state_since)::int,
                                     r.rssi, r.since_restart::int) order by r.machine)
                   from laundry.machine_readings r where r.boot_id = n.boot_id and r.seq = n.seq)))),
         n.observed_at, 1::smallint) as replay_result
from newest n;
