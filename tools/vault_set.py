"""Create or replace a Supabase Vault secret from an environment variable, without printing it.

    .venv/bin/python tools/vault_set.py <vault name> <ENV_VAR>
    .venv/bin/python tools/vault_set.py hc_db_ping_url HC_DB_PING_URL
    .venv/bin/python tools/vault_set.py push_hook_secret PUSH_HOOK_SECRET

Needs SUPABASE_ACCESS_TOKEN. Prints only whether the stored copy has the right length.
Stdlib only; run from a venv.
"""
import json
import os
import re
import sys
import urllib.request

REF = "gcxxytnkouvllfioqqlv"


def sql(query):
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": query}).encode(), method="POST",
        headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
                 "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    name, var = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z0-9_]+", name):
        sys.exit("vault name must be lowercase letters, digits and _")
    value = os.environ.get(var, "")
    if not value:
        sys.exit(f"{var} is not set")
    if "$v$" in value or "\n" in value:
        sys.exit(f"{var} contains characters this tool won't quote")
    if "SUPABASE_ACCESS_TOKEN" not in os.environ:
        sys.exit("SUPABASE_ACCESS_TOKEN is not set")

    exists = sql(f"select count(*) as n from vault.secrets where name = '{name}'")[0]["n"]
    if exists:
        sql(f"select vault.update_secret((select id from vault.secrets where name = '{name}'), $v${value}$v$)")
    else:
        sql(f"select vault.create_secret($v${value}$v$, '{name}')")
    stored = sql(f"select length(decrypted_secret) as n from vault.decrypted_secrets where name = '{name}'")[0]["n"]
    print(f"{'updated' if exists else 'created'} {name}; stored length matches: {stored == len(value)}")


if __name__ == "__main__":
    main()
