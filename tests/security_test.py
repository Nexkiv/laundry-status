"""Security test for the laundry-status Supabase project (stdlib only).

Two halves:
  1. Catalog: what anon/authenticated can reach must be EXACTLY the planned surface
     (6 read views + ingest + subscribe_push), so a later migration can't widen it silently.
  2. HTTP: attack the public API with the same publishable key the web page ships.

Needs env: SUPABASE_ACCESS_TOKEN (catalog queries + cleanup), SUPABASE_DEVICE_TOKEN (ingest tests).
Test rows use their own boot ids and are deleted at the end. Run: .venv/bin/python tests/security_test.py
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CFG = json.loads((ROOT / "config.public.json").read_text())
URL, KEY = CFG["SUPABASE_URL"], CFG["SUPABASE_PUBLISHABLE_KEY"]
REF = URL.split("//")[1].split(".")[0]

VIEWS = {"scanner_status", "machine_status", "recent_events", "usage_by_hour", "usage_recent", "liveness_hourly"}
RPCS = {"ingest", "subscribe_push"}
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
    return json.load(urllib.request.urlopen(req))


def api(method, path, body=None, headers=None):
    """Call the public Data API with the publishable key. Returns (status, parsed body or text, headers)."""
    h = {"apikey": KEY, "Content-Type": "application/json", **(headers or {})}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req)
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


def new_boot():
    b = uuid.uuid4().hex
    TEST_BOOTS.append(b)
    return b


def snapshot(seq, age=0):
    return {"k": "s", "seq": seq, "age": age, "l": 1, "lr": -68, "ok": 10, "lost": 0, "heap": 90, "blk": 60,
            "drop": 0, "rej": 0, "skip": 0,
            "m": [[n, 0, 60, -70, 0] for n in range(1, 7)]}


# ---------------------------------------------------------------- 1. catalog
req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/postgrest",
                             headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"]})
exposed = json.load(urllib.request.urlopen(req)).get("db_schema")   # print only this field: the response holds secrets
check("Data API exposes only the public schema", exposed == "public", exposed)
rows = sql("""
  select r.rolname as role, n.nspname as schema, c.relname as name, p.priv
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join (values ('anon'), ('authenticated')) r(rolname)
  cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
  where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'f', 'p')
    and has_table_privilege(r.rolname, c.oid, p.priv)""")
anon_tables = {(x["name"], x["priv"]) for x in rows if x["role"] == "anon"}
auth_tables = {(x["name"], x["priv"]) for x in rows if x["role"] == "authenticated"}
check("anon table privileges == SELECT on the 6 views", anon_tables == {(v, "SELECT") for v in VIEWS},
      sorted(anon_tables ^ {(v, "SELECT") for v in VIEWS}) or "")
check("authenticated has no table privileges", not auth_tables, sorted(auth_tables) or "")

rows = sql("""
  select r.rolname as role, n.nspname as schema, p.proname as name
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

# ---------------------------------------------------------------- 2. public API: reads
for v in sorted(VIEWS):
    status, body, _ = api("GET", f"/rest/v1/{v}?limit=1")
    check(f"GET view {v} -> 200", status == 200, status)
for t in ("snapshots", "machine_readings", "devices", "push_subscriptions", "call_counters"):
    status, _, _ = api("GET", f"/rest/v1/{t}?limit=1")
    check(f"GET private table {t} -> not served", status in (401, 404), status)

# ---------------------------------------------------------------- 3. public API: writes through views
for method, path, body in [("POST", "/rest/v1/recent_events", {"machine": 1}),
                           ("PATCH", "/rest/v1/machine_status?machine=eq.1", {"state": "free"}),
                           ("DELETE", "/rest/v1/recent_events?machine=eq.1", None),
                           ("DELETE", "/rest/v1/usage_by_hour?dow=eq.1", None)]:
    status, _, _ = api(method, path, body)
    # Postgres rejects writes to these views twice: they are not updatable (LIMIT/GROUP BY/joins ->
    # 55000, which PostgREST reports as 500) and anon has no write privilege (catalog check above).
    check(f"{method} {path.split('?')[0]} -> refused", status >= 400, status)
for fn in ("store_batch", "rollup", "retention", "watchdog", "bump"):
    status, _, _ = api("POST", f"/rest/v1/rpc/{fn}", {})
    check(f"private function {fn} -> not callable", status in (401, 404), status)
status, body, _ = api("POST", "/graphql/v1", {"query": "{ __typename }"})
check("GraphQL endpoint serves nothing", not (status == 200 and isinstance(body, dict) and body.get("data")), status)

# ---------------------------------------------------------------- 4. ingest()
boot = new_boot()
good = {"v": 1, "boot": boot, "rows": [snapshot(1, age=1500)]}
check("ingest with no token -> 401", ingest(good, token="")[0] == 401)
check("ingest with wrong token -> 401", ingest(good, token="x" * 64)[0] == 401)
status, body, _ = ingest(good)
check("valid batch -> 200, 1 snapshot stored", status == 200 and body.get("snapshots") == 1, (status, body))
status, body, _ = ingest(good)
check("same batch again -> 200, 0 stored (idempotent)", status == 200 and body.get("snapshot_dups") == 1, (status, body))
SHAPE = "select coalesce(sum(n), 0)::int as n from laundry.call_counters where kind = 'ingest_reject_shape'"
before = sql(SHAPE)[0]["n"]
bad = {"v": 1, "boot": boot, "rows": [dict(snapshot(2), evil="<script>")]}
check("unknown key -> 400", ingest(bad)[0] == 400)
bad = {"v": 1, "boot": boot, "rows": [snapshot(3), {"k": "e", "seq": 1, "age": 0, "t": 0, "n": "1", "mod": None, "real": 1}]}
status, _, _ = ingest(bad)
stored = sql(f"select count(*) as n from laundry.snapshots where boot_id = '{boot}' and seq = 3")[0]["n"]
check("batch with one bad row -> 400 and nothing stored", status == 400 and stored == 0, (status, stored))
check("received_at in the payload -> 400 (server-owned field)",
      ingest({"v": 1, "boot": boot, "rows": [dict(snapshot(4), received_at="2020-01-01")]})[0] == 400)
big = {"v": 1, "boot": boot, "rows": [snapshot(i) for i in range(10, 160)]}   # ~38 KB
check("oversize batch (>32 KB) -> 413", ingest(big)[0] == 413)
after = sql(SHAPE)[0]["n"]
check("the 3 shape refusals were counted (counter commits on a 4xx)", after == before + 3, f"{before} -> {after}")

# Quota: more than 10 calls in one minute -> 429 with Retry-After.
statuses, retry_after = [], None
for i in range(12):
    s, _, h = ingest({"v": 1, "boot": boot, "rows": [snapshot(200 + i)]})
    statuses.append(s)
    retry_after = retry_after or (h.get("Retry-After") if s == 429 else None)
check("12 calls in a minute -> 429 with Retry-After", 429 in statuses and retry_after is not None,
      f"{statuses.count(200)} ok, {statuses.count(429)} limited, Retry-After={retry_after}")

# ---------------------------------------------------------------- 5. subscribe_push()
s, _, _ = api("POST", "/rest/v1/rpc/subscribe_push",
              {"sub": {"endpoint": "https://evil.example.com/x", "keys": {"p256dh": "A" * 87, "auth": "B" * 22}}})
check("push endpoint outside the browser push services -> 400", s == 400, s)
s, _, _ = api("POST", "/rest/v1/rpc/subscribe_push",
              {"sub": {"endpoint": "https://fcm.googleapis.com/fcm/send/test-" + uuid.uuid4().hex,
                       "keys": {"p256dh": "<script>", "auth": "B" * 22}}})
check("malformed push keys -> 400", s == 400, s)
endpoint = "https://fcm.googleapis.com/fcm/send/test-" + uuid.uuid4().hex
s, body, _ = api("POST", "/rest/v1/rpc/subscribe_push",
                 {"sub": {"endpoint": endpoint, "expirationTime": None, "keys": {"p256dh": "A" * 87, "auth": "B" * 22}}})
check("valid subscription -> 200, expires in 180 min", s == 200 and body.get("expires_in_minutes") == 180, (s, body))

# ---------------------------------------------------------------- cleanup
ids = ",".join(f"'{b}'" for b in TEST_BOOTS)
sql(f"""delete from laundry.snapshots where boot_id in ({ids});
        delete from laundry.events where boot_id in ({ids});
        delete from laundry.boots where boot_id in ({ids});
        delete from laundry.push_subscriptions where endpoint like 'https://fcm.googleapis.com/fcm/send/test-%';""")
print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)
