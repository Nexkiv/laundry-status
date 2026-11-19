-- Single board (2026-11-18): the laundry-room board now scans Bluetooth and uploads over Wi-Fi
-- itself, as device 2 with its own token. Device 1 (the old two-board relay) keeps its token so the
-- old boards can be plugged back in as a rollback. No schema change: the snapshot format is the same.

-- Device 2's real hash is set by hand (docs/runbook.md, "Rotate the device token"); on a fresh
-- project this placeholder can never match a token.
insert into laundry.devices (id, name, token_sha256) values
  (2, 'laundry-room', extensions.gen_random_bytes(32))
on conflict (id) do nothing;

comment on column laundry.snapshots.link_rssi is
  'dBm, null = unknown. Device 1: ESP-NOW signal from the laundry-room listener. '
  'Device 2 and later: the single board''s Wi-Fi signal.';
