"""Security test for the laundry-status Supabase project (stdlib only).

Runs against the LIVE project in config.public.json, with the real device token:
  1. Catalog: what anon/authenticated can reach must be EXACTLY the planned surface
     (3 read views + ingest + subscribe_push), so a later migration can't widen it silently.
  2. HTTP: attack the public API with the same publishable key the web page ships.
  3. The alert rule, inside a transaction that is always rolled back (no push is sent).

Effects on the live system while it runs (about a minute):
  - Test snapshots are backdated an hour and show washers in use, so they are never the newest row:
    the page, the scanner status and the alert rule never see them.
  - The quota test fills the shared 10-calls-a-minute ingest quota, so the board gets 429 and
    retries for about a minute (its outbox keeps the rows).
  - One new boot id is created, which counts toward the board's 3-new-boots-an-hour quota.
Test rows are deleted at the end, even when a check or a request fails.

Needs env: SUPABASE_ACCESS_TOKEN (catalog queries + cleanup), SUPABASE_DEVICE_TOKEN (ingest tests).
Run: .venv/bin/python tests/security_test.py
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CFG = json.loads((ROOT / "config.public.json").read_text())
URL, KEY = CFG["SUPABASE_URL"], CFG["SUPABASE_PUBLISHABLE_KEY"]
REF = URL.split("//")[1].split(".")[0]

VIEWS = {"scanner_status", "machine_status", "recent_events"}
RPCS = {"ingest", "subscribe_push"}
PRIVATE_FNS = ("store_batch", "store_snapshot_row", "store_event_row", "boot_of", "client_key",
               "rollup", "retention", "watchdog", "bump")
TEST_PREFIX = "https://fcm.googleapis.com/fcm/send/test-"
HOUR_MS = 3_600_000
TEST_BOOTS = []
failures = 0


def check(name, ok, detail=""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  {name:<62} {detail}")


def sql(query):
    """Run SQL as the project owner through the Management API (admin side, not the public API)."""
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": query}).encode(), method="POST",
        headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
                 "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def api(method, path, body=None, headers=None):
    """Call the public Data API with the publishable key. Returns (status, parsed body or text, headers)."""
    h = {"apikey": KEY, "Content-Type": "application/json", **(headers or {})}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req, timeout=60)
        status, raw, hdrs = r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        status, raw, hdrs = e.code, e.read(), e.headers
    try:
        return status, json.loads(raw or b"null"), hdrs
    except json.JSONDecodeError:
        return status, raw[:200].decode(errors="replace"), hdrs


def ingest(batch, token=None):
    tok = os.environ["SUPABASE_DEVICE_TOKEN"] if token is None else token
    return api("POST", "/rest/v1/rpc/ingest", {"p": batch}, {"x-device-token": tok})


def subscribe(sub):
    return api("POST", "/rest/v1/rpc/subscribe_push", {"sub": sub})


def new_boot():
    b = uuid.uuid4().hex
    TEST_BOOTS.append(b)
    return b


def snapshot(seq, age=HOUR_MS):
    """A snapshot observed an hour ago with every washer in use: never the newest, never 'free'."""
    return {"k": "s", "seq": seq, "age": age, "l": 1, "lr": -68, "ok": 10, "lost": 0, "heap": 90, "blk": 60,
            "drop": 0, "rej": 0, "skip": 0,
            "m": [[n, 1, 60, -70, 0] for n in range(1, 7)]}


def test_sub(min_free=None, **extra):
    sub = {"endpoint": TEST_PREFIX + uuid.uuid4().hex, "expirationTime": None,
           "keys": {"p256dh": "A" * 87, "auth": "B" * 22}, **extra}
    if min_free is not None:
        sub["min_free"] = min_free
    return sub


def catalog():
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/postgrest",
                                 headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"]})
    exposed = json.load(urllib.request.urlopen(req, timeout=60)).get("db_schema")   # this field only: the response holds secrets
    check("Data API exposes only the public schema", exposed == "public", exposed)

    expected_tables = {(v, "SELECT") for v in VIEWS}
    rows = sql("""
      select r.rolname as role, c.relname as name, p.priv
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      cross join (values ('anon'), ('authenticated')) r(rolname)
      cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
      where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'f', 'p')
        and has_table_privilege(r.rolname, c.oid, p.priv)""")
    anon_tables = {(x["name"], x["priv"]) for x in rows if x["role"] == "anon"}
    auth_tables = {(x["name"], x["priv"]) for x in rows if x["role"] == "authenticated"}
    check("anon table privileges == SELECT on the 3 views", anon_tables == expected_tables,
          sorted(anon_tables ^ expected_tables) or "")
    check("authenticated has no table privileges", not auth_tables, sorted(auth_tables) or "")

    rows = sql("""
      select r.rolname as role, p.proname as name
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      cross join (values ('anon'), ('authenticated')) r(rolname)
      where n.nspname = 'public' and has_function_privilege(r.rolname, p.oid, 'EXECUTE')""")
    anon_fns = {x["name"] for x in rows if x["role"] == "anon"}
    auth_fns = {x["name"] for x in rows if x["role"] == "authenticated"}
    check("anon can EXECUTE exactly ingest + subscribe_push", anon_fns == RPCS, sorted(anon_fns ^ RPCS) or "")
    check("authenticated can EXECUTE nothing exposed", not auth_fns, sorted(auth_fns) or "")

    rows = sql("select has_schema_privilege('anon', 'laundry', 'USAGE') as a, has_schema_privilege('authenticated', 'laundry', 'USAGE') as b")
    check("no USAGE on private schema laundry", not rows[0]["a"] and not rows[0]["b"])
    rows = sql("select count(*) as n from pg_extension where extname = 'pg_graphql'")
    check("pg_graphql is not installed", rows[0]["n"] == 0)
    rows = sql("""select p.proname, p.prosecdef, coalesce(array_to_string(p.proconfig, ','), '') as cfg
                  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname in ('ingest', 'subscribe_push')""")
    check("RPCs are SECURITY DEFINER with search_path pinned",
          len(rows) == 2 and all(r["prosecdef"] and "search_path=" in r["cfg"] for r in rows))


def reads():
    for v in sorted(VIEWS):
        status, _, _ = api("GET", f"/rest/v1/{v}?limit=1")
        check(f"GET view {v} -> 200", status == 200, status)
    for t in ("snapshots", "machine_readings", "devices", "push_subscriptions", "call_counters", "usage_by_hour"):
        status, _, _ = api("GET", f"/rest/v1/{t}?limit=1")
        check(f"GET {t} -> not served", status in (401, 404), status)


def view_writes():
    for method, path, body in [("POST", "/rest/v1/recent_events", {"machine": 1}),
                               ("PATCH", "/rest/v1/machine_status?machine=eq.1", {"state": "free"}),
                               ("DELETE", "/rest/v1/recent_events?machine=eq.1", None),
                               ("DELETE", "/rest/v1/machine_status?machine=eq.1", None)]:
        status, _, _ = api(method, path, body)
        # Postgres rejects writes to these views twice: they are not updatable (LIMIT/joins -> 55000,
        # which PostgREST reports as 500) and anon has no write privilege (catalog check above).
        check(f"{method} {path.split('?')[0]} -> refused", status >= 400, status)
    for fn in PRIVATE_FNS:
        status, _, _ = api("POST", f"/rest/v1/rpc/{fn}", {})
        check(f"private function {fn} -> not callable", status in (401, 404), status)
    status, body, _ = api("POST", "/graphql/v1", {"query": "{ __typename }"})
    check("GraphQL endpoint serves nothing", not (status == 200 and isinstance(body, dict) and body.get("data")), status)


def ingest_tests():
    boot = new_boot()
    good = {"v": 1, "boot": boot, "rows": [snapshot(1)]}
    check("ingest with no token -> 401", ingest(good, token="")[0] == 401)
    check("ingest with wrong token -> 401", ingest(good, token="x" * 64)[0] == 401)
    status, body, _ = ingest(good)
    check("valid batch -> 200, 1 snapshot stored", status == 200 and body.get("snapshots") == 1, (status, body))
    status, body, _ = ingest(good)
    check("same batch again -> 200, 0 stored (idempotent)", status == 200 and body.get("snapshot_dups") == 1, (status, body))
    shape = "select coalesce(sum(n), 0)::int as n from laundry.call_counters where kind = 'ingest_reject_shape'"
    before = sql(shape)[0]["n"]
    check("unknown key -> 400", ingest({"v": 1, "boot": boot, "rows": [dict(snapshot(2), evil="<script>")]})[0] == 400)
    bad = {"v": 1, "boot": boot, "rows": [snapshot(3), {"k": "e", "seq": 1, "age": HOUR_MS, "t": 0, "n": "1", "mod": None, "real": 1}]}
    status, _, _ = ingest(bad)
    stored = sql(f"select count(*) as n from laundry.snapshots where boot_id = '{boot}' and seq = 3")[0]["n"]
    check("batch with one bad row -> 400 and nothing stored", status == 400 and stored == 0, (status, stored))
    check("received_at in the payload -> 400 (server-owned field)",
          ingest({"v": 1, "boot": boot, "rows": [dict(snapshot(4), received_at="2020-01-01")]})[0] == 400)
    big = {"v": 1, "boot": boot, "rows": [snapshot(i) for i in range(10, 160)]}   # ~38 KB
    check("oversize batch (>32 KB) -> 413", ingest(big)[0] == 413)
    after = sql(shape)[0]["n"]
    check("the 3 shape refusals were counted (counter commits on a 4xx)", after == before + 3, f"{before} -> {after}")

    # Quota: more than 10 calls in one calendar minute -> 429 with Retry-After. Calls until the
    # first 429, so crossing a minute boundary only means a few more calls.
    statuses, retry_after = [], None
    for i in range(25):
        s, _, h = ingest({"v": 1, "boot": boot, "rows": [snapshot(200 + i)]})
        statuses.append(s)
        if s == 429:
            retry_after = h.get("Retry-After")
            break
    check("over 10 calls in a minute -> 429 with Retry-After", 429 in statuses and retry_after is not None,
          f"{statuses.count(200)} ok, then {statuses[-1]}, Retry-After={retry_after}")


def subscribe_tests():
    s, _, _ = subscribe(dict(test_sub(), endpoint="https://evil.example.com/x"))
    check("push endpoint outside the browser push services -> 400", s == 400, s)
    s, _, _ = subscribe(dict(test_sub(), keys={"p256dh": "<script>", "auth": "B" * 22}))
    check("malformed push keys -> 400", s == 400, s)
    for bad in (0, 7, "2"):
        s, _, _ = subscribe(test_sub(min_free=bad))
        check(f"min_free {bad!r} -> 400", s == 400, s)
    s, _, _ = subscribe(test_sub(machine=1))
    check("old per-machine key -> 400", s == 400, s)
    s, body, _ = subscribe(test_sub(min_free=3))
    check("valid subscription -> 200, min_free 3, expires in 180 min",
          s == 200 and body.get("min_free") == 3 and body.get("expires_in_minutes") == 180, (s, body))


def push_function_tests():
    for name, hdrs in (("no hook secret", {}), ("wrong hook secret", {"x-hook-secret": "x" * 64})):
        s, _, _ = api("POST", "/functions/v1/push", {"free": 1, "subscriptions": []}, hdrs)
        check(f"push function with {name} -> 403", s == 403, s)


def alert_rule_tests():
    """The alert trigger, run inside a DO block that always raises: everything rolls back,
    including the queued push request, so nothing is sent and no live row changes."""
    boot = uuid.uuid4().hex
    try:
        sql(f"""do $$
        declare b uuid := '{boot}'; t timestamptz := now() + interval '1 hour'; out jsonb := '{{}}';
        begin
          insert into laundry.boots values (b, 1, now());
          insert into laundry.push_subscriptions (endpoint, p256dh, auth, min_free, expires_at)
          select '{TEST_PREFIX}rule-' || k, repeat('A', 87), repeat('B', 22), k, now() + interval '1 hour'
          from generate_series(1, 3) k;
          -- newest snapshot (dated ahead so a live one can't overtake it): washers 1-2 free, 3-6 in use
          insert into laundry.snapshots values (b, 1, now(), t, 1, -60, 1, 0, 100, 80, 0, 0, 0);
          insert into laundry.machine_readings
          select b, 1, k, t, case when k <= 2 then 0 else 1 end, t, false, -60 from generate_series(1, 6) k;

          insert into laundry.events values (b, 1, now(), now(), 0, 1, null, false);             -- door bump
          set constraints laundry.notify_free immediate; set constraints laundry.notify_free deferred;
          out := out || jsonb_build_object('bump', (select count(*) from laundry.push_subscriptions where endpoint like '%/test-rule-%'));
          insert into laundry.events values (b, 2, now(), now() - interval '5 minutes', 0, 1, null, true);  -- old event
          set constraints laundry.notify_free immediate; set constraints laundry.notify_free deferred;
          out := out || jsonb_build_object('old', (select count(*) from laundry.push_subscriptions where endpoint like '%/test-rule-%'));
          insert into laundry.events values (b, 3, now(), now(), 0, 3, null, true);              -- washer 3 not free
          set constraints laundry.notify_free immediate; set constraints laundry.notify_free deferred;
          out := out || jsonb_build_object('busy', (select count(*) from laundry.push_subscriptions where endpoint like '%/test-rule-%'));
          insert into laundry.events values (b, 4, now(), now(), 0, 1, null, true);              -- real: 2 free
          set constraints laundry.notify_free immediate;
          out := out || jsonb_build_object('left', (select string_agg(right(endpoint, 1), ',') from laundry.push_subscriptions where endpoint like '%/test-rule-%'));
          raise exception 'RESULT %', out;
        end $$;""")
        check("alert rule block rolled back", False, "the DO block did not raise")
        return
    except urllib.error.HTTPError as e:
        m = re.search(r"RESULT (\{[^}]*\})", e.read().decode(errors="replace"))
    if not m:
        check("alert rule block ran", False, "no RESULT in the error")
        return
    res = json.loads(m.group(1).replace('\\"', '"'))
    check("door bump -> no alert", res.get("bump") == 3, res.get("bump"))
    check("event older than 2 min -> no alert", res.get("old") == 3, res.get("old"))
    check("washer no longer free -> no alert", res.get("busy") == 3, res.get("busy"))
    check("real load, 2 free -> alerts min_free 1 and 2 once, keeps 3", res.get("left") == "3", res.get("left"))
    left = sql(f"select count(*) as n from laundry.boots where boot_id = '{boot}'")[0]["n"]
    check("alert rule test left nothing behind", left == 0, left)


def cleanup():
    stmts = [f"delete from laundry.push_subscriptions where endpoint like '{TEST_PREFIX}%';"]
    if TEST_BOOTS:
        ids = ",".join(f"'{b}'" for b in TEST_BOOTS)
        stmts.append(f"""delete from laundry.snapshots where boot_id in ({ids});
                         delete from laundry.events where boot_id in ({ids});
                         delete from laundry.boots where boot_id in ({ids});""")
    sql("\n".join(stmts))


def main():
    try:
        catalog()
        reads()
        view_writes()
        ingest_tests()
        subscribe_tests()
        push_function_tests()
        alert_rule_tests()
    finally:
        cleanup()
    print(f"\n{failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
