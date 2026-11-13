# Runbook

What to do when an alert fires or a key has to change. Queries live in `sql/`; paste them into the
Supabase SQL Editor. Never paste a secret into the SQL Editor or a chat: secrets move from env vars
with the commands below.

## 1. Which alert fired?

| Board check | DB check | Most likely | First step |
|---|---|---|---|
| red | red | Board, power or Wi-Fi is down | Same as before this project: see the private repo's `SYSTEM_OVERVIEW.md` |
| green | red | Board is fine, but nothing reaches the database | Open the board's LAN page and read the **Database** line (below) |
| green | red, data fresh | Database over 300 MB, 100+ refused calls since the start of the previous hour, or alerts failing | Sections 4 and 5 |
| green | green | Page says "Can't reach the status service" | The publishable key was rotated (section 3) or GitHub Pages is down |

The **Database** line on the board's LAN page starts with the last answer it got:

| Shows | Meaning | Fix |
|---|---|---|
| `HTTP 200 · stored N rows` | Healthy | — |
| `HTTP 400 · REJECTED …` | The server refused the data itself (dead letter: those rows are dropped) | Read the reason after `REJECTED`; usually firmware and database disagree on the format |
| `HTTP 429 · retry in …` | Over quota: 10 calls a minute, or 3+ new boots in an hour (a reboot loop), or `tests/security_test.py` just ran | Wait a minute. If it continues, check for reboots, then roll back the last OTA |
| `HTTP 5xx` / `no answer · retry in …` | Supabase down or paused | Section 6 |
| `HTTP 401/403/404 · retry in …` | Device token, key or API out of step (a 404 can briefly appear while a migration loads) | Section 2 or 3; the board keeps retrying and loses nothing it still holds |
| `skipped: low memory` | Heap guard is holding the rows | Usually clears itself; reboot the board if it doesn't |
| `… · N dropped` | Outbox overflowed (about 40 minutes of rows); those rows are lost | `sql/2_continuity.sql` names the gap |

Afterwards, `sql/1_liveness.sql` should show a write under a minute old and about 60 snapshots in the last hour.

## 2. Rotate the device token

The database stores only a SHA-256 of the token. Between steps 3 and 4 the board gets 401 and keeps
its rows for a retry, but the upload restarts it and its outbox lives in memory, so those few minutes
are lost.

1. Make a new token and put it in your shell profile like the other secrets:
   `export SUPABASE_DEVICE_TOKEN=$(openssl rand -hex 32)`. Open a new terminal.
2. Build first, so the next step and the upload are back to back: `firmware/build.sh compile` (private repo).
3. Print the hash (safe to share; it can't be reversed into the token):
   `printf %s "$SUPABASE_DEVICE_TOKEN" | shasum -a 256 | cut -c1-64`, then in the SQL Editor:
   `update laundry.devices set token_sha256 = decode('<hash>', 'hex') where id = 1;`
4. Upload right away: `firmware/build.sh run --device laundry.local --no-logs`.
5. Check: the Database line shows `HTTP 200`.

## 3. Swap a rotated key

| Key | Lives in | After rotating |
|---|---|---|
| Supabase publishable key (public) | `config.public.json`; `firmware/supabase.env` (private repo) | Update both. Push this repo; OTA the board |
| `SUPABASE_ACCESS_TOKEN` | Laptop env only (CLI, Management API, `tools/`) | Update the env var. Nothing deployed uses it |
| VAPID key pair | Edge Function secrets `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY`; the public key in `config.public.json` | `npx web-push generate-vapid-keys`; set both with `supabase secrets set … --project-ref gcxxytnkouvllfioqqlv`; update `config.public.json` and push. Alerts already armed were made with the old key: they fail and expire within 3 h. The next "Notify me" on that browser notices the old key and subscribes again |
| `PUSH_HOOK_SECRET` | Edge Function secret **and** Vault `push_hook_secret`; the two must match | `export PUSH_HOOK_SECRET=$(openssl rand -hex 32)`, then `supabase secrets set PUSH_HOOK_SECRET="$PUSH_HOOK_SECRET" --project-ref gcxxytnkouvllfioqqlv` and `.venv/bin/python tools/vault_set.py push_hook_secret PUSH_HOOK_SECRET` |
| `HC_DB_PING_URL` | Vault `hc_db_ping_url` | `.venv/bin/python tools/vault_set.py hc_db_ping_url HC_DB_PING_URL` |
| Device token | Board firmware; hash in `laundry.devices` | Section 2 |
| Board-only secrets (Wi-Fi, OTA password, ntfy topic, board ping URL) | Board firmware | Private repo's `SYSTEM_OVERVIEW.md` |

The legacy JWT secret is revoked, and the legacy `anon`/`service_role` keys are disabled. Nothing uses them.

## 4. Size or abuse alarm

```sql
select pg_size_pretty(pg_database_size(current_database()));
select kind, sum(n) from laundry.call_counters
where bucket > now() - interval '2 hours' group by kind order by 2 desc;
```

- **Size:** expected growth is a few MB a month. Run `select laundry.retention();` and check
  `select jobname, active from cron.job;`; `laundry-retention` should run nightly.
- **Refusals:** `*_reject_token` means someone is guessing tokens, `*_reject_quota` means someone is
  flooding. Quotas already cap the cost of both. Rotating the publishable key does not help: the new
  key is published in the page too. One client flooding alert sign-ups is limited on its own
  (`subscribe_client_limited`, 10 a minute and 20 active alerts per IP) and doesn't count as a refusal.

## 5. Alerts not arriving

The watchdog also goes silent when alerts fail, so the DB check turns red for this too.

```sql
select kind, sum(n) from laundry.call_counters
where kind like 'push%' and bucket > now() - interval '1 day' group by kind;
select q.created_at, r.status_code, left(r.content::text, 200) as reply
from laundry.push_requests q left join net._http_response r on r.id = q.id
order by q.created_at desc limit 20;
```

| Shows | Meaning | Fix |
|---|---|---|
| `push_no_secret` | Vault has no `push_hook_secret` | Section 3, `PUSH_HOOK_SECRET` row |
| reply 403 | Vault and function secrets differ | Set both again from the same env var (section 3) |
| reply 401 | Function redeployed with JWT checking on | Redeploy with the command below |
| reply 5xx or `push_error` | Function or trigger failing | Function logs in the dashboard; `push_error` keeps the subscriptions |
| `{"sent":0,"failed":N}` | The browsers' push services refused | Usually expired subscriptions; nothing to fix |

Deploy the function (settings are in `supabase/config.toml`; dependencies pinned by `deno.lock`):
`supabase functions deploy push --project-ref gcxxytnkouvllfioqqlv --use-api --no-verify-jwt`.
It needs three function secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `PUSH_HOOK_SECRET`.

## 6. Supabase paused or down

- Check status.supabase.com, then open the project in the dashboard. A free project pauses after a week
  without activity. This one is written every minute, so a pause means the board was offline for days.
  Click **Restore project** soon: a project that stays paused too long can no longer be restored from
  the dashboard.
- The board retries with backoff on its own. Its outbox keeps about 40 minutes of rows; anything older
  shows up as `dropped`. The pg_cron jobs (rollup, retention, watchdog) resume on restore.
- Check with `sql/1_liveness.sql` and `sql/2_continuity.sql`.

## 7. Roll back the board

The last-known-good firmware and the USB recovery steps are in the private repo's `SYSTEM_OVERVIEW.md`.
