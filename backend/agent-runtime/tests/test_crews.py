"""The crew node, and the fallback that makes it optional.

CrewAI is not in the default image — see the note in `crews.py`. That makes the
fallback load-bearing rather than defensive: an agent that opts into a panel
must still run correctly on an image where the library is absent, producing an
ordinary single-model diagnosis instead of failing.
"""

from __future__ import annotations

import pytest

from agent_runtime.app.state import AgentState, Evidence, Phase, ToolSpecWire
from agent_runtime.app.toolbox import Toolbox
from agent_runtime.graph import crews
from agent_runtime.graph.context import RunContext
from agent_runtime.graph.phases import HypothesisOut
from tests import fakes
from tests.test_reduce import descriptor

READ = ToolSpecWire(name="workflow_3", description="Collect figures.", mutating=False)


@pytest.fixture
def graph_state(monkeypatch):
    model = fakes.install(monkeypatch, fakes.ScriptedModel(script=[]))
    state = AgentState(agent_ref="test", input="Why is the host slow?", phase=Phase.HYPOTHESIZE)
    state.ledger.append(
        Evidence(
            evidence_id=31,
            tool="workflow_3",
            ok=True,
            excerpt="/var 94%",
            digest="d",
            phase=Phase.GATHER,
        )
    )
    context = RunContext(
        agent=descriptor(),
        toolbox=Toolbox(specs=[READ], unavailable=[]),
        persona="You are a Linux analyst.",
    )
    return {"state": state, "ctx": context}, model


def test_the_panel_falls_back_when_crewai_is_absent(graph_state, monkeypatch):
    """The default image has no crewai; the run must still produce findings."""
    state_and_ctx, model = graph_state
    model.script = [
        HypothesisOut(
            findings=[{"summary": "/var is at 94%.", "severity": "critical", "cites": [31]}],
            need_more=False,
        )
    ]

    # Simulate the default image: the import inside _deliberate raises.
    def unavailable(*args, **kwargs):
        raise ModuleNotFoundError("No module named 'crewai'")

    monkeypatch.setattr(crews, "_deliberate", unavailable)

    result = crews.panel()(state_and_ctx)
    state = result["state"]

    assert [finding.summary for finding in state.findings] == ["/var is at 94%."]
    assert state.findings[0].cites == [31]
    # Read-only agent, so the fallback routes onward to REPORT, not PLAN.
    assert state.phase is Phase.REPORT


def test_an_empty_panel_result_also_falls_back(graph_state, monkeypatch):
    """A crew that returns nothing is not a diagnosis of 'nothing is wrong'."""
    state_and_ctx, model = graph_state
    model.script = [HypothesisOut(findings=[], need_more=False)]
    monkeypatch.setattr(crews, "_deliberate", lambda *a, **k: [])

    result = crews.panel()(state_and_ctx)

    assert result["state"].phase is Phase.REPORT


def test_a_crew_finding_citing_an_unknown_id_is_dropped(graph_state, monkeypatch):
    """Same rule as the single-model path: an id this run never issued cannot pass."""
    state_and_ctx, _ = graph_state
    monkeypatch.setattr(
        crews,
        "_deliberate",
        lambda *a, **k: [
            {"summary": "Disk is full.", "severity": "critical", "cites": [31, 999]}
        ],
    )

    result = crews.panel()(state_and_ctx)
    findings = result["state"].findings

    assert findings[0].cites == [31]


def test_the_reply_parser_survives_prose_around_the_json():
    assert crews._parse('Here is my answer:\n[{"summary": "x"}]\nHope that helps.') == [
        {"summary": "x"}
    ]
    assert crews._parse("I could not decide.") == []
    assert crews._parse("[not json]") == []


# ------------------------------------------------ structured-output guards ---


def test_prose_instead_of_structure_is_a_readable_failure(monkeypatch, graph_state):
    """A weaker model answering in prose must not crash three frames later.

    LangChain reports that as ``parsed=None`` with NO ``parsing_error``. Passing
    it through produced `AttributeError: 'NoneType' object has no attribute
    'findings'` on a live run — a stack trace that says nothing about the cause
    or the fix.
    """
    from agent_runtime.graph import phases
    from agent_runtime.graph.context import StructuredOutputError

    state_and_ctx, model = graph_state

    class ProseOnly:
        def with_structured_output(self, schema, include_raw=False):
            return self

        def invoke(self, messages, config=None):
            return {"raw": None, "parsed": None, "parsing_error": None}

    monkeypatch.setattr(state_and_ctx["ctx"], "_model", ProseOnly())

    with pytest.raises(StructuredOutputError) as caught:
        phases.hypothesize(state_and_ctx)

    message = str(caught.value)
    assert "HYPOTHESIZE" in message, "the phase must be named"
    assert "HypothesisOut" in message
    assert "model" in message.lower(), "and the fix pointed at"


def test_a_parsing_error_is_also_reported_as_structured_output_failure(monkeypatch, graph_state):
    from agent_runtime.graph import phases
    from agent_runtime.graph.context import StructuredOutputError

    state_and_ctx, _ = graph_state

    class Broken:
        def with_structured_output(self, schema, include_raw=False):
            return self

        def invoke(self, messages, config=None):
            return {"raw": None, "parsed": None, "parsing_error": "not valid JSON"}

    monkeypatch.setattr(state_and_ctx["ctx"], "_model", Broken())

    with pytest.raises(StructuredOutputError) as caught:
        phases.hypothesize(state_and_ctx)
    assert "not valid JSON" in str(caught.value)
