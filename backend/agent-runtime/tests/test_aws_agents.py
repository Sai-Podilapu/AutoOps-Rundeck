"""The two AWS investigators.

What these pin is the thing that justifies an agent over three scheduled
reports: it asks for several read-only tools in ONE turn, then reasons across
their combined output with the tools taken away.
"""

from __future__ import annotations

import pytest

from agent_runtime import agents
from agent_runtime.app.reduce import reduce
from agent_runtime.app.state import (
    AgentDescriptor,
    Directive,
    Phase,
    ReduceRequest,
    StartEvent,
    ToolResultsEvent,
    ToolResultWire,
    ToolSpecWire,
    Vendor,
)
from agent_runtime.graph.phases import HypothesisOut, TriageOut
from tests import fakes

EXPOSURE_TOOLS = [
    ToolSpecWire(name="workflow_11", description="S3 Public Access Audit.", mutating=False),
    ToolSpecWire(name="workflow_12", description="IAM Access Key Audit.", mutating=False),
    ToolSpecWire(name="workflow_13", description="Security Group Ingress Audit.", mutating=False),
]


def descriptor(ref: str) -> AgentDescriptor:
    return AgentDescriptor(
        ref=ref, version="1.0.0", model="claude-sonnet-5",
        vendor=Vendor.ANTHROPIC, credentials={"apiKey": "k"},
    )


@pytest.mark.parametrize(
    "ref,expected_tools",
    [
        ("aws.public_exposure_auditor",
         ["RD-149-s3-public-access-audit", "RD-145-iam-access-key-audit",
          "RD-137-security-group-audit"]),
        ("aws.cost_anomaly_investigator",
         ["RD-141-cost-anomaly-report", "RD-142-idle-resource-report",
          "RD-136-s3-storage-cost-report"]),
    ],
)
def test_the_manifest_names_the_workflows_that_exist(ref, expected_tools):
    """A ref typo here fails the delivery, not the run — publish.py checks it."""
    manifest = agents.resolve(ref).spec.manifest
    assert [tool.ref for tool in manifest.tools] == expected_tools


@pytest.mark.parametrize(
    "ref", ["aws.public_exposure_auditor", "aws.cost_anomaly_investigator"]
)
def test_every_tool_is_declared_read_only(ref):
    """Both agents inspect. Nothing in either grant can change an account.

    If one of these ever flips to mutating, the agent silently gains a PLAN and
    GATE phase it was never designed for — so the assertion is on the manifest,
    not on the prose in the persona.
    """
    manifest = agents.resolve(ref).spec.manifest
    assert all(not tool.mutating for tool in manifest.tools)
    assert manifest.approval_required is False
    # And it survives publication, which is what rollout actually reads.
    assert all(tool["mutating"] is False for tool in manifest.to_json()["tools"])


@pytest.mark.parametrize(
    "ref", ["aws.public_exposure_auditor", "aws.cost_anomaly_investigator"]
)
def test_neither_agent_declares_an_acting_phase(ref):
    spec = agents.resolve(ref).spec
    assert Phase.PLAN not in spec.phases
    assert Phase.GATE not in spec.phases
    assert Phase.ACT not in spec.phases


def test_it_gathers_all_three_audits_in_one_turn(monkeypatch):
    """The correlation case only works if it collects everything before judging.

    Three tool calls in a single assistant turn is also what proves the runtime
    handles parallel calls — vendors require them all answered together, and a
    turn that dribbled them out one at a time would triple the round trips.
    """
    model = fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                TriageOut(restated="Full exposure review of the account.", can_proceed=True),
                fakes.reply(
                    "Collecting all three audits.",
                    [
                        {"name": "workflow_11", "args": {"Region": "us-east-1"}, "id": "c1"},
                        {"name": "workflow_12", "args": {"MaxKeyAgeDays": 90}, "id": "c2"},
                        {"name": "workflow_13", "args": {"Region": "us-east-1"}, "id": "c3"},
                    ],
                ),
            ]
        ),
    )

    response = reduce(
        ReduceRequest(
            agent=descriptor("aws.public_exposure_auditor"),
            tools=EXPOSURE_TOOLS,
            state=None,
            event=StartEvent(input="Review public exposure on the AWS account."),
            run_id=91,
        )
    )

    assert response.directive is Directive.CALL_TOOLS
    assert [c.name for c in response.tool_calls] == ["workflow_11", "workflow_12", "workflow_13"]
    # All three were OFFERED, because all three are read-only.
    assert set(model.bound[0].names) == {"workflow_11", "workflow_12", "workflow_13"}


def test_it_correlates_across_the_three_and_cites_each(monkeypatch):
    """The finding that justifies the agent: a chain, citing every link."""
    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                TriageOut(restated="Exposure review.", can_proceed=True),
                fakes.reply(
                    "Collecting.",
                    [
                        {"name": "workflow_11", "args": {}, "id": "c1"},
                        {"name": "workflow_12", "args": {}, "id": "c2"},
                        {"name": "workflow_13", "args": {}, "id": "c3"},
                    ],
                ),
            ]
        ),
    )
    first = reduce(
        ReduceRequest(
            agent=descriptor("aws.public_exposure_auditor"),
            tools=EXPOSURE_TOOLS,
            state=None,
            event=StartEvent(input="Review public exposure."),
        )
    )

    model = fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                fakes.reply("I have all three audits."),
                HypothesisOut(
                    findings=[
                        {
                            "summary": "Bucket acme-backups is public and sg-0a1 admits the "
                                       "world on 22, while an active key is 412 days old.",
                            "severity": "critical",
                            "cites": [501, 502, 503],
                        }
                    ],
                    need_more=False,
                ),
                fakes.reply(
                    "**acme-backups is readable by anyone** [e:501]. The same account has "
                    "sg-0a1 open on port 22 to 0.0.0.0/0 [e:503], and an active access key "
                    "412 days old [e:502]."
                ),
            ]
        ),
    )

    final = reduce(
        ReduceRequest(
            agent=descriptor("aws.public_exposure_auditor"),
            tools=EXPOSURE_TOOLS,
            state=first.state,
            event=ToolResultsEvent(
                results=[
                    ToolResultWire(call_id="c1", ok=True, evidence_id=501,
                                   content='{"summary":{"total":40,"public":1}}'),
                    ToolResultWire(call_id="c2", ok=True, evidence_id=502,
                                   content='{"summary":{"activeOverAge":1}}'),
                    ToolResultWire(call_id="c3", ok=True, evidence_id=503,
                                   content='{"summary":{"groupsOpenToInternet":1}}'),
                ]
            ),
        )
    )

    assert final.directive is Directive.FINISH
    # One finding resting on all three collections — that is the correlation.
    assert final.state["findings"][0]["cites"] == [501, 502, 503]
    assert sorted(final.citations) == [501, 502, 503]
    assert final.uncited_claims == []
    # HYPOTHESIZE ran with nothing bound, so it could not re-scan to avoid
    # committing to an answer.
    assert model.phases == ["GATHER", "HYPOTHESIZE", "REPORT"]
    assert len(model.bound) == 1, "only GATHER binds tools"


def test_a_failed_audit_cannot_be_reported_as_clean(monkeypatch):
    """Unknown is not safe. A failed collection is still citable evidence."""
    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                TriageOut(restated="Exposure review.", can_proceed=True),
                fakes.reply("Collecting.", [{"name": "workflow_11", "args": {}, "id": "c1"}]),
            ]
        ),
    )
    first = reduce(
        ReduceRequest(
            agent=descriptor("aws.public_exposure_auditor"),
            tools=EXPOSURE_TOOLS,
            state=None,
            event=StartEvent(input="Review public exposure."),
        )
    )

    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                fakes.reply("The S3 audit failed."),
                HypothesisOut(
                    findings=[
                        {"summary": "S3 exposure could not be assessed.",
                         "severity": "unknown", "cites": [601]}
                    ],
                    need_more=False,
                ),
                fakes.reply("The S3 audit could not complete [e:601], so bucket exposure "
                            "is unknown for this account."),
            ]
        ),
    )

    final = reduce(
        ReduceRequest(
            agent=descriptor("aws.public_exposure_auditor"),
            tools=EXPOSURE_TOOLS,
            state=first.state,
            event=ToolResultsEvent(
                results=[
                    ToolResultWire(call_id="c1", ok=False, evidence_id=601,
                                   content="AccessDenied: s3:GetBucketAcl")
                ]
            ),
        )
    )

    assert final.directive is Directive.FINISH
    assert final.citations == [601], "a failed collection must remain citable"
    assert final.state["findings"][0]["severity"] == "unknown"


def test_every_structured_schema_has_a_description():
    """Bedrock's Converse API rejects a tool whose description is empty.

    LangChain builds that description from the pydantic class docstring, so a
    schema without one produces `toolConfig.tools[0].toolSpec.description,
    value: 0, valid min length: 1` — on Bedrock only. Anthropic and OpenAI
    accept it, which means a missing docstring passes every local test and
    fails on exactly one vendor, in the middle of a live run. This caught it.
    """
    from agent_runtime.graph import phases

    schemas = [phases.TriageOut, phases.HypothesisOut, phases.PlanOut,
               phases.FindingOut, phases.ActionOut]
    for schema in schemas:
        doc = (schema.__doc__ or "").strip()
        assert doc, f"{schema.__name__} needs a docstring — Bedrock rejects an empty one"
