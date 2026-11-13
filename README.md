# Laundry status

Which washers are free right now, from anywhere: **https://nexkiv.github.io/laundry-status/**

A Bluetooth scanner (two ESP32 boards, firmware in a private repo) listens to the washers' broadcasts and pushes their state to a free Supabase Postgres database every minute and on every change. This page reads that database, and a "Notify me when N or more are free" button sends one Web Push alert.

```
washers ─BLE─► listener ESP32 ─ESP-NOW─► base ESP32 ─HTTPS─► Supabase ingest() ─► views ─► this page (30 s poll)
                                                                    └─ trigger ─► Edge Function ─► Web Push
pg_cron: hourly rollup · nightly retention · 5-min watchdog ─► healthchecks.io
```

## Repo

| Path | What |
|---|---|
| `index.html`, `app.js`, `styles.css` | The page: room map, washer list, last 24 h, alerts. Strict CSP; every value is set with `textContent` |
| `sw.js`, `manifest.webmanifest` | Service worker (shows the one alert, then unsubscribes) and the installable app manifest |
| `config.public.json` | Supabase URL, publishable key, VAPID public key: public by design |
| `supabase/migrations/` | Schema, ingest and subscribe RPCs, views, alert trigger, cron jobs, grants (0001–0004, all applied) |
| `supabase/functions/push/` | Edge Function that sends the Web Push alerts (`deno.lock` frozen) |
| `sql/` | Demo queries: liveness, continuity, idempotency, replay, today vs typical |
| `tests/security_test.py` | Exact public surface, attack cases, quotas, the alert rule (55 checks) |
| `tools/vault_set.py` | Copies a secret from an env var into Supabase Vault without printing it |
| `docs/runbook.md` | What to do when an alert fires or a key has to change |

## Data

| Layer | Tables | Kept |
|---|---|---|
| Bronze | `raw_adverts` (the 11/09 capture, 33,519 adverts) | forever |
| Silver | `snapshots`, `machine_readings`, `events` | 90 days |
| Gold | `usage_hourly`, `liveness_hourly` | forever |

All in the private schema `laundry`. The public API serves only three views (`scanner_status`, `machine_status`, `recent_events`) and two RPCs (`ingest` with a device token, `subscribe_push`).

## Run the checks

```sh
python3 -m venv .venv
SUPABASE_ACCESS_TOKEN=… SUPABASE_DEVICE_TOKEN=… .venv/bin/python tests/security_test.py
```

The test runs against the live project; its docstring lists the brief effects on the board.

## Future work

- **Alert code as its own step (review R11, option 2).** Today a trigger on `events` decides and sends alerts at commit, wrapped so an error can't block storage. Moving it into `ingest()` after `store_batch()`, with the rule as a side-effect-free function, would make the rule unit-testable without a rolled-back transaction, keep the seed and replay paths away from alert code, and move the function URL into Vault.
- **Busy-hours chart** from `usage_hourly` (the views for it were dropped until a chart reads them).
- **ESP-NOW encryption** between the boards (forged frames are an accepted risk today).
