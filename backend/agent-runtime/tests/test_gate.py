"""The acting half of the kit: plan, gate, human verdict, report.

The behaviour under test is the one that separates an operations agent from a
chatbot with tools. It must propose rather than act, hand a human something
structured, and — the part that matters most — treat a rejection as an ANSWER.
An agent that responds to "no" by looking for another way in is worse than no
agent at all, and :func:`test_a_rejection_goes_to_the_report_not_back_to_plan`
is the test that says so.
"""

from __future__ import annotations

import pytest

from agent_runtime import agents
from agent_runtime.agents.spec import AgentSpec, Manifest
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
from agent_runtime.graph import kit
from agent_runtime.graph.phases import HypothesisOut, PlanOut, TriageOut
from tests import fakes

REF = "test.remediator"

PHASES = (
    Phase.TRIAGE,
    Phase.GATHER,
    Phase.HYPOTHESIZE,
    Phase.PLAN,
    Phase.GATE,
    Phase.ACT,
    Phase.REPORT,
)

READ = ToolSpecWire(name="workflow_3", description="Collect disk figures.", mutating=False)
WRITE = ToolSpecWire(name="job_9", description="Delete unattached volumes.", mutating=True)


@pytest.fixture(autouse=True)
def remediator(monkeypatch):
    """An agent that can act, registered only for these tests."""
    spec = AgentSpec(
        manifest=Manifest(
            ref=REF,
            version="1.0.0",
            name="Test remediator",
            description="Plans and executes a change behind a human gate.",
            domain="Test",
            model="claude-sonnet-5",
        ),
        persona="You clean up unattached volumes.",
        build_graph=lambda: kit.build(list(PHASES)),
        phases=PHASES,
    )
    monkeypatch.setitem(agents.REGISTRY, REF, spec)
    return spec


def descriptor() -> AgentDescriptor:
    return AgentDescriptor(
        ref=REF,
        version="1.0.0",
        model="claude-sonnet-5",
        vendor=Vendor.ANTHROPIC,
        credentials={"apiKey": "k"},
    )


def request(state, event) -> ReduceRequest:
    return ReduceRequest(
        agent=descriptor(), tools=[READ, WRITE], state=state, event=event, run_id=7
    )


def reach_the_gate(monkeypatch):
    """Drives a run from START to the point where it wants human approval."""
    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                TriageOut(restated="Clean up unattached volumes.", can_proceed=True),
                fakes.reply("Looking.", [{"name": "workflow_3", "args": {}, "id": "c1"}]),
            ]
        ),
    )
    first = reduce(request(None, StartEvent(input="Clean up unattached volumes in eu-west-1.")))
    assert first.directive is Directive.CALL_TOOLS

    model = fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                fakes.reply("I have what I need."),
                HypothesisOut(
                    findings=[
                        {
                            "summary": "vol-abc has been unattached for 40 days.",
                            "severity": "warning",
                            "cites": [21],
                        }
                    ],
                    need_more=False,
                ),
                PlanOut(
                    actions=[
                        {
                            "tool": "job_9",
                            "arguments": {"VolumeId": "vol-abc"},
                            "intent": "Delete the unattached volume.",
                            "blast_radius": "One EBS volume in eu-west-1.",
                            "rollback": "Restore from the recovery snapshot.",
                            "cites": [21],
                        }
                    ]
                ),
            ]
        ),
    )
    second = reduce(
        request(
            first.state,
            ToolResultsEvent(
                results=[
                    ToolResultWire(
                        call_id="c1", ok=True, evidence_id=21, content="vol-abc unattached 40d"
                    )
                ]
            ),
        )
    )
    return second, model


def test_the_run_stops_at_the_gate_with_a_structured_proposal(monkeypatch):
    """It proposes; it does not act. The blast radius and rollback survive."""
    gated, model = reach_the_gate(monkeypatch)

    assert gated.directive is Directive.CALL_TOOLS
    assert [call.name for call in gated.tool_calls] == ["job_9"]
    assert gated.tool_calls[0].arguments == {"VolumeId": "vol-abc"}
    assert gated.phase is Phase.ACT

    planned = gated.state["planned"]
    assert planned[0]["rollback"] == "Restore from the recovery snapshot."
    assert planned[0]["blast_radius"] == "One EBS volume in eu-west-1."
    assert planned[0]["cites"] == [21]

    # PLAN reasons with no tools bound at all — it cannot act while deciding
    # what to propose. Only GATHER bound anything.
    assert [binding.names for binding in model.bound] == [["workflow_3"]]


def test_a_rejection_goes_to_the_report_not_back_to_plan(monkeypatch):
    """The single most important routing decision in the kit.

    A rejected action must end the run with an explanation. Re-planning after
    a human says no is how an agent talks its way around a control.
    """
    gated, _ = reach_the_gate(monkeypatch)

    model = fakes.install(
        monkeypatch,
        fakes.ScriptedModel(script=[fakes.reply("Nothing was deleted [e:21].")]),
    )
    final = reduce(
        request(
            gated.state,
            ToolResultsEvent(
                results=[
                    ToolResultWire(
                        call_id=gated.tool_calls[0].id,
                        ok=False,
                        evidence_id=22,
                        content="Priya REJECTED this request, so the automation did not run.",
                        decision="REJECTED",
                        decided_by="Priya",
                    )
                ]
            ),
        )
    )

    assert final.directive is Directive.FINISH
    assert model.phases == ["REPORT"], "a rejection must not re-enter PLAN or GATE"
    assert any("rejected" in finding["summary"].lower() for finding in final.state["findings"])
    assert "Priya" in str(final.state["findings"])


def test_an_approval_carries_on_to_the_report(monkeypatch):
    gated, _ = reach_the_gate(monkeypatch)

    model = fakes.install(
        monkeypatch,
        fakes.ScriptedModel(script=[fakes.reply("Deleted vol-abc [e:22].")]),
    )
    final = reduce(
        request(
            gated.state,
            ToolResultsEvent(
                results=[
                    ToolResultWire(
                        call_id=gated.tool_calls[0].id,
                        ok=True,
                        evidence_id=22,
                        content="Run #91 finished SUCCEEDED. Snapshot snap-xyz retained.",
                        decision="APPROVED",
                        decided_by="Priya",
                    )
                ]
            ),
        )
    )

    assert final.directive is Directive.FINISH
    assert final.citations == [22]
    assert model.phases == ["REPORT"]


def test_a_proposal_naming_an_ungranted_tool_never_reaches_a_human(monkeypatch):
    """Approving it could not run it anyway, and showing it implies it can."""
    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                TriageOut(restated="Clean up.", can_proceed=True),
                fakes.reply("Looking.", [{"name": "workflow_3", "args": {}, "id": "c1"}]),
            ]
        ),
    )
    first = reduce(request(None, StartEvent(input="Clean up.")))

    fakes.install(
        monkeypatch,
        fakes.ScriptedModel(
            script=[
                fakes.reply("Done looking."),
                HypothesisOut(findings=[], need_more=False),
                PlanOut(
                    actions=[
                        {"tool": "job_404", "arguments": {}, "intent": "Delete everything."}
                    ],
                    do_nothing_reason="",
                ),
                fakes.reply("No action was possible."),
            ]
        ),
    )
    final = reduce(
        request(
            first.state,
            ToolResultsEvent(
                results=[ToolResultWire(call_id="c1", ok=True, evidence_id=1, content="ok")]
            ),
        )
    )

    assert final.directive is Directive.FINISH
    assert final.state["planned"] == []


def test_gather_never_sees_the_destructive_tool_even_on_an_acting_agent(monkeypatch):
    """The narrowing is not a property of read-only agents; it is per phase."""
    _, model = reach_the_gate(monkeypatch)

    for binding in model.bound:
        assert "job_9" not in binding.names
