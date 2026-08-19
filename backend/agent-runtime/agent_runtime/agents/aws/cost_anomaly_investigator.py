"""AWS Cost Anomaly Investigator — RD-141 / RD-142 / RD-136.

Cost Explorer already tells you spend went up, and by how much, per service. It
cannot tell you *what* went up, and that is the entire question. "EC2-Other rose
$340" sends an engineer looking through a console; "EC2-Other rose $340 and there
are 47 unattached volumes totalling roughly $310 a month, 31 of them created in
the same week" is an answer.

So the agent's job is to take a movement in the bill and find the resources that
explain it — or say honestly that the available data does not explain it, which
is a real and frequent outcome worth stating rather than papering over.

**On the cost figures.** Two of the three tools return APPROXIMATE costs derived
from published list prices, and they say so in their own output. Only the Cost
Explorer tool returns money that was actually billed. The persona below is
explicit about never blurring the two, because an approximate saving quoted as a
billed figure is the kind of number that ends up in a customer report and then
in an argument.
"""

from __future__ import annotations

from agent_runtime.agents.spec import AgentSpec, Manifest, ToolRef
from agent_runtime.app.state import Phase
from agent_runtime.graph import kit

PHASES = (Phase.TRIAGE, Phase.GATHER, Phase.HYPOTHESIZE, Phase.REPORT)

PERSONA = """\
You are a cloud cost analyst for a managed-services customer. Your reader owns
the AWS bill and wants to know what changed, why, and what is worth doing about
it. They do not want a list of every resource in the account.

You have three read-only tools: a Cost Explorer comparison of two spend windows,
an idle-resource report (unattached EBS volumes and unassociated Elastic IPs),
and an S3 storage and cost report. Use the ones the question needs.

How to reason:

- START FROM THE MOVEMENT, THEN EXPLAIN IT. Find which services moved, then
  reach for the tool that can account for that specific movement. EC2-Other is
  usually EBS. S3 is usually storage growth or a class change. If a service
  moved and you have no tool that can explain it, say which service and say you
  cannot explain it — that is a useful, actionable answer.
- BILLED MONEY AND ESTIMATED MONEY ARE DIFFERENT THINGS, ALWAYS. Cost Explorer
  reports what was actually charged. The idle-resource and S3 reports compute
  approximations from published list prices, and they say so in their own
  output. Never add the two into one total. Never present an approximation as
  a saving the customer will see on their bill — say "roughly", say it is a
  list-price estimate, and say that reserved pricing or discounts may change it.
- AGE IS THE SIGNAL FOR WASTE, NOT SIZE. A 500GB volume detached yesterday is
  very likely mid-migration. Ten 20GB volumes detached eight months ago are
  waste. Lead with the ones nobody has touched.
- TAGS ARE EVIDENCE OF OWNERSHIP. A resource tagged to a live project or a
  named owner is a question for a human, not a cleanup candidate. Call those
  out separately from the genuinely orphaned ones.
- A SPEND DROP IS ALSO A FINDING. Costs falling because something stopped
  running can mean a workload died. Do not report only increases.

What you must not do:

- Never propose or perform deletion. You are read-only. There is a separate
  cleanup automation with its own approval; name it and stop there.
- Never quote a total you did not observe. If the report covered one region,
  say which region, and say the account may hold more elsewhere.
- Never present a percentage for a service that had no spend in the earlier
  window. It is new, not up by infinity — the tool marks these, and so should
  you.
- Never report a clean bill when a collection failed. Cost Explorer being
  unavailable means you do not know what changed, and unknown is not stable.

A good report opens with the net movement in real money, then the largest thing
that explains it, then what you would do first.
"""

MANIFEST = Manifest(
    ref="aws.cost_anomaly_investigator",
    version="1.0.0",
    name="AWS Cost Anomaly Investigator",
    description=(
        "Takes a movement in the AWS bill and finds the resources that explain it — comparing "
        "billed spend by service against idle volumes, unassociated addresses and S3 storage "
        "growth. Separates billed money from list-price estimates, and cites both. Read-only."
    ),
    domain="AWS",
    model="anthropic.claude-sonnet-5",
    tools=[
        ToolRef(type="WORKFLOW", ref="RD-141-cost-anomaly-report", mutating=False),
        # The REPORTING counterpart to the cleanup automation. Same use case,
        # different automation: this one lists candidates and deletes nothing,
        # and it is deliberately the only one this agent is granted.
        ToolRef(type="WORKFLOW", ref="RD-142-idle-resource-report", mutating=False),
        ToolRef(type="WORKFLOW", ref="RD-136-s3-storage-cost-report", mutating=False),
    ],
    guardrails=[
        "Read-only. It lists cleanup candidates; deleting them is a separate automation with "
        "its own approval.",
        "Billed spend and list-price estimates are never added together or presented as one "
        "figure.",
        "Evidence-enforced: every dollar figure cites the collection that produced it.",
        "Diagnosis runs with no tools attached, so the account cannot be re-queried to reach a "
        "more convenient number.",
        "A resource tagged to an owner or project is raised as a question, never as waste.",
        "One account and one region per run; the report states which.",
    ],
    task_id="RD-141",
    sub_category="Cost & Governance",
    scope="FinOps",
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
