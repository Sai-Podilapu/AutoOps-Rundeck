"""CrewAI, used for exactly one thing.

A crew earns its cost in one situation: when a set of observations genuinely
admits several competing explanations from different specialisms, and the
failure mode of a single model is to settle on the first plausible one. A host
that is slow could be a storage problem, a network problem or a noisy
neighbour, and a single pass tends to commit to whichever the evidence happens
to mention first. Three specialists each arguing from their own discipline, then
a synthesiser ranking them, surfaces the second-best explanation instead of
burying it.

**Where it is deliberately NOT used.** Not for gathering — a crew with tools is
several agents calling real automations with no single place to enforce the
allow-list. Not for reporting — the evidence rule needs one author. Not as a
general replacement for :func:`~agent_runtime.graph.phases.hypothesize`, which
remains the default; a crew is opt-in per agent and costs roughly three times
as many tokens.

The crew never sees a tool. It reads the evidence ledger, which is text by the
time it gets here, and returns findings. Containing it behind one node type is
what keeps a second orchestration framework from spreading through the codebase
— everything outside this module deals in LangGraph nodes.

**CrewAI is an optional dependency and is not in the default image.** Installing
`crewai` drags in `crewai-tools`, and with it a browser-automation stack,
`pytube` and `youtube-transcript-api` — a large attack surface to acquire for a
feature no shipped agent uses yet, in a service that reasons about production
infrastructure. So the import is lazy and :func:`panel` degrades to the ordinary
single-model :func:`~agent_runtime.graph.phases.hypothesize` node when it is
absent. An image that serves a crew-backed agent installs `.[crew]`.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from agent_runtime.app import evidence
from agent_runtime.app.state import Finding, Phase
from agent_runtime.graph import prompts
from agent_runtime.graph.phases import GraphState, GraphStateUpdate, hypothesize

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Specialist:
    """One discipline's view of the same evidence."""

    role: str
    goal: str
    backstory: str


#: The default panel for infrastructure triage. An agent may pass its own.
INFRASTRUCTURE = (
    Specialist(
        role="Storage engineer",
        goal="Decide whether the evidence points at a storage or filesystem cause.",
        backstory=(
            "You have spent a decade on filesystems, block devices and the ways they fail "
            "slowly. You know that a full filesystem and a filesystem that is filling fast "
            "are different incidents, and that inode exhaustion looks like nothing at all "
            "until it looks like everything."
        ),
    ),
    Specialist(
        role="Linux platform engineer",
        goal="Decide whether the evidence points at CPU, memory, scheduling or the kernel.",
        backstory=(
            "You know that load average without core count is meaningless, that memory in "
            "page cache is memory doing its job, and that a machine can be at 100% CPU and "
            "perfectly healthy. You are the person who stops the team restarting a service "
            "that was never the problem."
        ),
    ),
    Specialist(
        role="Network engineer",
        goal="Decide whether the evidence points at connectivity, latency or name resolution.",
        backstory=(
            "You have seen more incidents caused by DNS than you care to count, and you are "
            "sceptical of any diagnosis that assumes the host is the problem when the "
            "evidence only shows that something timed out."
        ),
    ),
)


def panel(specialists: tuple[Specialist, ...] = INFRASTRUCTURE):
    """A hypothesize node backed by a crew, for agents that want one.

    Falls back to the single-model node when CrewAI is unavailable — which is
    the default image — or when the crew fails. A diagnosis produced by one
    competent model is worth far more than a run that died because an optional
    orchestration library was missing, and the fallback is the code path every
    other agent already uses.
    """

    def node(graph_state: GraphState) -> GraphStateUpdate:
        state, ctx = graph_state["state"], graph_state["ctx"]
        try:
            findings = _deliberate(graph_state, specialists)
        except Exception as exc:  # noqa: BLE001 - see the docstring
            log.warning("Crew unavailable for %s, using the single-model path: %s", ctx.agent.ref, exc)
            return hypothesize(graph_state)

        if not findings:
            return hypothesize(graph_state)

        state.visit(Phase.HYPOTHESIZE)
        known = state.cited()
        state.findings = [
            Finding(
                summary=item.get("summary", "").strip(),
                severity=item.get("severity", "unknown"),
                cites=[value for value in item.get("cites", []) if value in known],
            )
            for item in findings
            if item.get("summary")
        ]
        state.phase = Phase.PLAN if ctx.toolbox.has_mutating() else Phase.REPORT
        return {"state": state}

    return node


def _deliberate(graph_state: GraphState, specialists: tuple[Specialist, ...]) -> list[dict]:
    """Runs the panel and returns its ranked findings as plain dicts."""
    from crewai import Agent, Crew, Process, Task

    state, ctx = graph_state["state"], graph_state["ctx"]
    ledger = evidence.render(state)
    brief = (
        f"{prompts.EVIDENCE_RULE}\n\n"
        f"The operator asked:\n\n{state.input}\n\n"
        f"Observations:\n\n{ledger}"
    )

    # No tools, on purpose — see the module docstring. `allow_delegation` is off
    # so each specialist argues its own discipline instead of handing the
    # question to whichever peer sounds most confident, which is the behaviour
    # that makes a panel worth running at all.
    crew_agents = [
        Agent(
            role=member.role,
            goal=member.goal,
            backstory=member.backstory,
            llm=ctx.model(),
            allow_delegation=False,
            verbose=False,
        )
        for member in specialists
    ]

    tasks = [
        Task(
            description=(
                f"{brief}\n\nFrom your discipline only, state what the evidence supports and "
                f"what it rules out. If it says nothing about your area, say so plainly — "
                f"'the collected data does not cover this' is a useful answer and inventing "
                f"a concern to look useful is not."
            ),
            expected_output="A short assessment from your discipline, citing observations as [e:<id>].",
            agent=member,
        )
        for member in crew_agents
    ]

    synthesiser = Agent(
        role="Incident lead",
        goal="Rank what the panel found and discard what the evidence does not support.",
        backstory=(
            "You run the bridge during incidents. You are ruthless about the difference "
            "between what was observed and what was inferred, and you would rather hand "
            "the on-call engineer two solid findings than six speculative ones."
        ),
        llm=ctx.model(),
        allow_delegation=False,
        verbose=False,
    )

    tasks.append(
        Task(
            description=(
                f"{brief}\n\nThe panel has reported. Produce the final findings, most serious "
                f"first. Drop anything the observations do not support, including from your "
                f"own panel — a specialist's confidence is not evidence. Return ONLY a JSON "
                f'array: [{{"summary": str, "severity": "critical"|"warning"|"info"|"unknown", '
                f'"cites": [int]}}]. Return [] if the observations support no finding.'
            ),
            expected_output='A JSON array of findings, or [].',
            agent=synthesiser,
            context=tasks[:],
        )
    )

    crew = Crew(
        agents=[*crew_agents, synthesiser],
        tasks=tasks,
        process=Process.sequential,
        verbose=False,
    )
    return _parse(str(crew.kickoff()))


def _parse(raw: str) -> list[dict]:
    """Pulls the JSON array out of a reply that may be wrapped in prose.

    Returns an empty list rather than raising: an unparseable answer means the
    caller falls back to the single-model path, which is a better outcome than
    a failed run.
    """
    text = raw.strip()
    start, end = text.find("["), text.rfind("]")
    if start < 0 or end <= start:
        return []
    try:
        parsed = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return []
    return [item for item in parsed if isinstance(item, dict)]
