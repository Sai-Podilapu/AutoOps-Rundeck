#!/usr/bin/env python3
"""Publish authored workflows and agents into the PLATFORM catalog.

    python backend/agent-service/agents/_schema/publish.py --dry-run
    AUTOOPS_PROVIDER_USER=... AUTOOPS_PROVIDER_PASSWORD=... \
        python backend/agent-service/agents/_schema/publish.py

Workflows are published BEFORE agents, and an agent whose referenced workflow
is not in the catalog is refused before anything is written — a delivered agent
whose allow-list resolves to nothing is worse than no agent at all.

Publishing goes through POST /api/provider/library rather than SQL so the
catalog rows get validation, a real `created_by` and an audit trail. The
credential is read from the environment and never written anywhere.

--print-sql emits the equivalent statements instead, for an operator who would
rather not put a provider password in their shell environment. That path skips
validation and audit, so it is a bootstrap convenience, not the normal route.

Re-running is safe: an item whose title already exists in the catalog is
updated in place rather than duplicated.
"""
import argparse
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent          # .../agents
WORKFLOW_ROOT = ROOT.parent / "workflows"                      # .../workflows
DEFAULT_BASE = os.environ.get("AUTOOPS_API", "http://localhost:8080/api")

# Keys RolloutService.rollOutAgent reads out of an AGENT catalog definition.
AGENT_DEFINITION_KEYS = ("description", "model", "instructions", "tools")


def load(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        sys.exit(f"{path}: not valid JSON — {exc}")


def discover():
    workflows = sorted(WORKFLOW_ROOT.glob("*/*.json")) if WORKFLOW_ROOT.exists() else []
    agents = sorted(p for p in ROOT.glob("*/*.json") if p.parent.name != "_schema")
    return workflows, agents


def check_consistency(workflows, agents):
    """Refuse to publish a set that cannot work once delivered."""
    problems = []
    by_task = {}

    for path in workflows:
        doc = load(path)
        by_task[doc["taskId"]] = doc

    for path in agents:
        doc = load(path)
        for tool in doc["tools"]:
            ref_task = re.match(r"^(RD-\d{3})-", tool["ref"])
            if not ref_task or ref_task.group(1) not in by_task:
                problems.append(
                    f"{doc['taskId']}: tool ref '{tool['ref']}' has no published "
                    f"workflow — the delivered agent would have no working tool"
                )
    return problems


def workflow_payload(doc):
    # nodes[] is what ExecutionEngine walks; inputs[] is what
    # InternalAgentDispatchController.workflowInputs returns as the form.
    definition = {"nodes": doc["nodes"], "inputs": doc["inputs"]}
    return {
        "title": doc["title"],
        "description": doc["description"],
        "type": "workflow",
        "category": doc.get("category", doc["domain"]),
        "premium": False,
        "definition": json.dumps(definition),
    }


def agent_payload(doc):
    definition = {k: doc[k] for k in AGENT_DEFINITION_KEYS if k in doc}
    return {
        "title": doc["name"],
        "description": doc["description"],
        "type": "agent",
        "category": doc["domain"],
        "premium": False,
        "definition": json.dumps(definition),
    }


class Api:
    def __init__(self, base, token):
        self.base, self.token = base.rstrip("/"), token

    def _call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}{path}", data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            sys.exit(f"{method} {path} failed: HTTP {exc.code} — {exc.read().decode()[:300]}")

    def catalog(self):
        return {i["title"]: i for i in self._call("GET", "/provider/library")}

    def create(self, payload):
        return self._call("POST", "/provider/library", payload)

    def update(self, item_id, payload):
        return self._call("PUT", f"/provider/library/{item_id}", payload)


def login(base, user, password):
    req = urllib.request.Request(
        f"{base.rstrip('/')}/auth/login",
        data=json.dumps({"email": user, "password": password}).encode(),
        method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        sys.exit(f"Login failed: HTTP {exc.code} — {exc.read().decode()[:200]}")
    token = body.get("accessToken") or body.get("access_token") or body.get("token")
    if not token:
        sys.exit(f"Login succeeded but no token in response: {list(body)}")
    return token


def sql_for(payload):
    """Bootstrap equivalent. tenant_id NULL is what makes a row PLATFORM catalog.

    `library_items` carries no unique key beyond its primary key, so
    ON DUPLICATE KEY UPDATE would never fire and a second run would duplicate
    every row. This emits update-then-insert-if-absent instead, which is
    idempotent AND preserves the row id — delivered tenant copies point back at
    it through `source_id`, so re-inserting would orphan every rollout.
    """
    esc = lambda s: (s or "").replace("\\", "\\\\").replace("'", "''")
    title = esc(payload["title"])
    kind = payload["type"].upper()
    description = esc(payload["description"])
    category = esc(payload["category"])
    definition = esc(payload["definition"])
    where = f"tenant_id IS NULL AND title = '{title}' AND type = '{kind}'"
    return (
        f"UPDATE autoops_core.library_items "
        f"SET description = '{description}', category = '{category}', "
        f"definition = '{definition}' "
        f"WHERE {where};\n"
        f"INSERT INTO autoops_core.library_items "
        f"(tenant_id, title, description, type, category, premium, definition, "
        f"installs, created_by) "
        f"SELECT NULL, '{title}', '{description}', '{kind}', '{category}', 0, "
        f"'{definition}', 0, 'publish.py' "
        f"FROM DUAL WHERE NOT EXISTS "
        f"(SELECT 1 FROM autoops_core.library_items WHERE {where});"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print the plan, write nothing")
    ap.add_argument("--print-sql", action="store_true", help="emit SQL instead of calling the API")
    ap.add_argument("--api", default=DEFAULT_BASE)
    args = ap.parse_args()

    workflows, agents = discover()
    if not workflows and not agents:
        sys.exit("nothing to publish")

    problems = check_consistency(workflows, agents)
    if problems:
        print("Refusing to publish:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    # Order matters: an agent references a workflow, so the workflow goes first.
    planned = [("workflow", p, workflow_payload(load(p))) for p in workflows] \
        + [("agent", p, agent_payload(load(p))) for p in agents]

    if args.print_sql:
        print("-- Platform catalog bootstrap. Review before running.")
        for _, _, payload in planned:
            print(sql_for(payload))
        return 0

    if args.dry_run:
        for kind, path, payload in planned:
            print(f"would publish {kind:9} {payload['title']!r}  ({path.relative_to(ROOT.parent)})")
        print(f"\n{len(planned)} item(s); nothing written")
        return 0

    user = os.environ.get("AUTOOPS_PROVIDER_USER")
    password = os.environ.get("AUTOOPS_PROVIDER_PASSWORD")
    if not (user and password):
        sys.exit("Set AUTOOPS_PROVIDER_USER and AUTOOPS_PROVIDER_PASSWORD, "
                 "or use --print-sql / --dry-run")

    api = Api(args.api, login(args.api, user, password))
    existing = api.catalog()
    created = updated = 0
    for kind, _, payload in planned:
        found = existing.get(payload["title"])
        if found:
            api.update(found["id"], payload)
            updated += 1
            print(f"updated  {kind:9} {payload['title']!r}")
        else:
            api.create(payload)
            created += 1
            print(f"created  {kind:9} {payload['title']!r}")
    print(f"\n{created} created, {updated} updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
