"""Phase narrowing, and the registry's refusal to guess."""

from __future__ import annotations

import pytest

from agent_runtime import agents
from agent_runtime.app.state import Phase, ToolCallWire, ToolSpecWire
from agent_runtime.app.toolbox import Toolbox

READ = ToolSpecWire(name="workflow_3", description="Collect health figures.", mutating=False)
WRITE = ToolSpecWire(name="job_9", description="Delete unattached volumes.", mutating=True)


@pytest.fixture
def box() -> Toolbox:
    return Toolbox(specs=[READ, WRITE], unavailable=[])


@pytest.mark.parametrize("phase", [Phase.TRIAGE, Phase.HYPOTHESIZE, Phase.PLAN, Phase.REPORT])
def test_thinking_phases_get_no_tools_at_all(box, phase):
    """A phase that can still call a tool will keep calling it."""
    assert box.for_phase(phase) == []


@pytest.mark.parametrize("phase", [Phase.GATHER, Phase.VERIFY])
def test_observing_phases_see_only_read_only_tools(box, phase):
    assert [spec.name for spec in box.for_phase(phase)] == ["workflow_3"]


@pytest.mark.parametrize("phase", [Phase.GATE, Phase.ACT])
def test_acting_phases_keep_the_read_only_tools_too(box, phase):
    """An action phase routinely needs a lookup to build its arguments."""
    assert {spec.name for spec in box.for_phase(phase)} == {"workflow_3", "job_9"}


def test_the_legacy_phase_sees_everything(box):
    """RESPOND reproduces the old loop, which never narrowed anything."""
    assert {spec.name for spec in box.for_phase(Phase.RESPOND)} == {"workflow_3", "job_9"}


def test_a_mutating_call_during_gather_is_refused_with_the_route_out(box):
    """A refusal that does not say what would have worked just repeats itself."""
    problem = box.check(Phase.GATHER, ToolCallWire(id="1", name="job_9"))

    assert problem is not None
    assert "changes state" in problem
    assert "approval" in problem


def test_an_invented_tool_name_is_refused_and_the_real_ones_listed(box):
    problem = box.check(Phase.GATHER, ToolCallWire(id="1", name="workflow_999"))

    assert "no tool called" in problem
    assert "workflow_3" in problem


def test_an_allowed_call_passes(box):
    assert box.check(Phase.GATHER, ToolCallWire(id="1", name="workflow_3")) is None


# ------------------------------------------------------------- registry ---


def test_an_unknown_ref_is_refused_and_never_resolved_loosely():
    """A corrupted catalog row must not become a different agent on production."""
    with pytest.raises(agents.UnknownAgent) as caught:
        agents.resolve("linux.server_health_chek")  # one letter out

    assert "linux.server_health_chek" in str(caught.value)


def test_no_ref_resolves_to_the_compatibility_agent():
    assert agents.resolve(None).spec.ref == agents.DEFAULT_REF


def test_a_version_mismatch_runs_current_and_says_so():
    """Refusing would break every tenant the moment the provider shipped an update."""
    resolution = agents.resolve("linux.server_health_check", "0.9.0")

    assert resolution.spec.version == "1.0.0"
    assert resolution.substituted_from == "0.9.0"
    assert "0.9.0" in resolution.note and "1.0.0" in resolution.note


def test_a_matching_version_reports_no_substitution():
    assert agents.resolve("linux.server_health_check", "1.0.0").note is None


def test_a_published_manifest_carries_no_persona_or_prompts():
    """The sealing guarantee, asserted rather than assumed.

    Checks the two things that actually matter: no field is NAMED for the
    persona, and no field CONTAINS it. A substring search for the word
    "persona" would be a weaker test that also fails on any description
    mentioning the concept — this compares against the real text.

    This is what fails if someone adds a convenience field to Manifest and
    accidentally ships the product into every customer's database.
    """
    import json

    for spec in agents.REGISTRY.values():
        published = spec.manifest.to_json()

        assert "persona" not in published
        assert "instructions" not in published
        assert "phases" not in published, "the phase list is authoring detail, not product"

        if spec.persona.strip():
            body = json.dumps(published)
            assert spec.persona not in body
            # Any substantial run of the persona leaking would be caught here;
            # a single shared sentence is what a description legitimately is.
            for paragraph in spec.persona.split("\n\n"):
                if len(paragraph.strip()) > 80:
                    assert paragraph.strip() not in body


def test_the_prompts_are_not_reachable_from_a_manifest():
    """The phase prompts are the product too, and ship only in this image."""
    import json

    from agent_runtime.graph import prompts

    body = json.dumps(agents.catalog())
    for prompt in (prompts.RUNTIME_PREAMBLE, prompts.GATHER, prompts.REPORT, prompts.EVIDENCE_RULE):
        assert prompt not in body
