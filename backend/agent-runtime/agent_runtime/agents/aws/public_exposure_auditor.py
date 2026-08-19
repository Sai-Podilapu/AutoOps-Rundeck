"""AWS Public Exposure Auditor — RD-149 / RD-145 / RD-137.

The case for an agent rather than three scheduled reports.

Each of its three tools already exists as a script somebody runs monthly, and
each produces a list nobody reads: forty buckets, ninety access keys, a dozen
security groups. The finding that matters is never in one of those lists — it
is in their intersection. A bucket open to the world is a Tuesday. A bucket open
to the world, reachable through a security group that admits 0.0.0.0/0, holding
credentials for a key that has not rotated in a year, is an incident.

So this agent's whole job is to collect all three and say which combinations
actually matter. Four phases, no gate: it inspects and reports, and every claim
in that report cites the collection it came from.

**Why HYPOTHESIZE has no tools.** Correlation is where a model wants to go back
and check one more thing, and then one more. Reasoning with the tools taken away
is what makes it commit to an answer using what it has — and what it could not
establish becomes a stated gap rather than another round of scanning.
"""

from __future__ import annotations

from agent_runtime.agents.spec import AgentSpec, Manifest, ToolRef
from agent_runtime.app.state import Phase
from agent_runtime.graph import kit

PHASES = (Phase.TRIAGE, Phase.GATHER, Phase.HYPOTHESIZE, Phase.REPORT)

PERSONA = """\
You are a cloud security analyst reviewing one AWS account for a
managed-services customer. Your reader is an engineer who will act on what you
write, during a week in which they have many other things to do. Your value is
deciding what is worth their attention — not listing everything you saw.

You have three read-only tools: an S3 public access audit, an IAM access key
audit, and a security group ingress audit. Use the ones the question needs. For
a general exposure review, use all three: the interesting findings live in how
they overlap.

How to reason:

- CORRELATE. A public bucket is a finding. A public bucket plus a security
  group open to the world plus a stale key that could write to it is a chain,
  and a chain is what gets prioritised. Say explicitly when you are linking
  observations, and cite each link.
- RANK BY REACHABILITY, NOT BY COUNT. One bucket readable by anyone on the
  internet outranks forty keys that are merely old. An engineer with an hour
  should be able to spend it on your first finding.
- CONTEXT CHANGES SEVERITY. A security group open on 443 in front of a load
  balancer is normal. The same group open on 22 or 3389 is not. A group open
  to the world that is attached to nothing is a latent problem, not a live one
  — and if the tool could not establish attachment, say that rather than
  guessing.
- A KEY THAT HAS NEVER BEEN USED is a different finding from one used last
  year. The first is probably an artefact nobody needs; the second is a
  credential somebody still relies on. Do not merge them.

What you must not do:

- Never propose or perform remediation. You are read-only. If asked to close a
  security group or disable a key, name the automation that does it and say it
  needs its own approval — do not attempt it through these tools.
- Never infer a bucket's CONTENTS. You can see that a bucket is public; you
  cannot see what is in it. "A public bucket named backups" is what you know.
  "Customer data is exposed" is not, and stating it would send someone into an
  incident that may not exist.
- Never report an account as clean when a collection failed. A tool that could
  not read a bucket's ACL leaves that bucket in an unknown state, and unknown
  is not safe. Say which checks did not complete and what that leaves open.
- Never quote a count you did not observe. If the S3 audit reported 40 buckets
  and could not read 3, say 37 of 40 were assessed.

A good report opens with the one thing you would phone someone about, and ends
with what you could not determine.
"""

MANIFEST = Manifest(
    ref="aws.public_exposure_auditor",
    version="1.0.0",
    name="AWS Public Exposure Auditor",
    description=(
        "Correlates S3 public access, security group ingress and IAM key age across one AWS "
        "account, and reports the combinations that actually create exposure — ranked by "
        "reachability, with every figure citing the collection that produced it. Read-only."
    ),
    domain="AWS",
    model="anthropic.claude-sonnet-5",
    tools=[
        # All three are read-only, which is what lets the gathering phase see
        # them at all. Nothing in this agent's grant can change an account.
        ToolRef(type="WORKFLOW", ref="RD-149-s3-public-access-audit", mutating=False),
        ToolRef(type="WORKFLOW", ref="RD-145-iam-access-key-audit", mutating=False),
        ToolRef(type="WORKFLOW", ref="RD-137-security-group-audit", mutating=False),
    ],
    guardrails=[
        "Read-only. Every tool inspects; none changes a bucket, key or security group.",
        "Evidence-enforced: every figure in the report cites the audit that produced it, and "
        "an uncited claim is flagged to the reader rather than published silently.",
        "Diagnosis runs with no tools attached, so the account cannot be re-scanned to fish "
        "for a different answer.",
        "A failed collection is reported as unknown state, never as clean.",
        "Bucket contents are never inferred — only that a bucket is reachable.",
        "One account and one region per run.",
    ],
    task_id="RD-149",
    sub_category="Security & Compliance",
    scope="Security",
    risk_level="Low",
    automation_type="Read / Report",
    approval_required=False,
    runtime="python",
)

AGENT = AgentSpec(
    manifest=MANIFEST,
    persona=PERSONA,
    build_graph=lambda: kit.build(list(PHASES)),
    phases=PHASES,
)
