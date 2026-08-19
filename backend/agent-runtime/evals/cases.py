"""The golden-case format, and how a case becomes a run.

A case is one recorded conversation: the agent, its tools, and a list of steps.
Each step supplies the event that arrived and the model replies that followed,
then states what the reducer should have decided.

**Why the model replies are recorded rather than generated.** The reducer is
pure, but a model is not. Replaying a case against a live vendor answers a
different and also useful question ("does the new prompt behave better on this
real input?") — but it costs money, needs credentials, and gives a different
answer every time, which makes it useless as a regression gate. Recording the
replies pins everything except our own code, so a failure means *we* changed
the behaviour. That is the only kind of failure a CI check should report.

The live comparison still exists; it lives in :mod:`evals.replay` under
``compare`` and is a separate, manual act.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from langchain_core.messages import AIMessage

from agent_runtime.app.state import AgentDescriptor, ToolSpecWire
from agent_runtime.graph import phases

#: Structured-output schemas a case may name. Explicit rather than resolved by
#: `getattr`, so a case file cannot reach an arbitrary class in this process.
SCHEMAS = {
    "TriageOut": phases.TriageOut,
    "HypothesisOut": phases.HypothesisOut,
    "PlanOut": phases.PlanOut,
}


class BadCase(ValueError):
    """A case file this harness cannot read."""


@dataclass
class Expectation:
    """What the reducer should have decided at one step."""

    directive: str | None = None
    phase: str | None = None
    tool_calls: list[str] | None = None
    #: Substrings the final report must contain. Deliberately not an exact
    #: match: the wording is the model's and will drift, but "does it still
    #: cite [e:21]" and "does it still say UNVERIFIED" are ours.
    output_contains: list[str] = field(default_factory=list)
    citations: list[int] | None = None
    has_uncited: bool | None = None


@dataclass
class Step:
    event: dict[str, Any]
    script: list[Any]
    expect: Expectation


@dataclass
class Case:
    name: str
    agent: AgentDescriptor
    tools: list[ToolSpecWire]
    steps: list[Step]
    unavailable: list[str] = field(default_factory=list)

    @property
    def phases_expected(self) -> list[str]:
        return [step.expect.phase for step in self.steps if step.expect.phase]


def load(path: Path) -> Case:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BadCase(f"{path.name}: not valid JSON — {exc}") from exc

    try:
        agent = AgentDescriptor.model_validate(
            {
                # A case never carries a credential. The offline harness does
                # not reach a vendor, and a golden file that contained a real
                # key would be a secret committed to the repository.
                "credentials": {"apiKey": "offline"},
                **raw["agent"],
            }
        )
        tools = [ToolSpecWire.model_validate(tool) for tool in raw.get("tools", [])]
        steps = [
            Step(
                event=step["event"],
                script=[_reply(item) for item in step.get("script", [])],
                expect=Expectation(**step.get("expect", {})),
            )
            for step in raw["steps"]
        ]
    except (KeyError, TypeError) as exc:
        raise BadCase(f"{path.name}: {exc}") from exc

    return Case(
        name=raw.get("name", path.stem),
        agent=agent,
        tools=tools,
        steps=steps,
        unavailable=raw.get("unavailable", []),
    )


def _reply(item: dict[str, Any]) -> Any:
    """One recorded model reply, as the runtime would have received it."""
    kind = item.get("type", "reply")

    if kind == "structured":
        schema = SCHEMAS.get(item.get("schema", ""))
        if schema is None:
            raise BadCase(
                f"unknown structured schema {item.get('schema')!r}; "
                f"known: {', '.join(sorted(SCHEMAS))}"
            )
        return schema.model_validate(item["value"])

    if kind == "reply":
        return AIMessage(
            content=item.get("text", ""),
            tool_calls=[
                {"name": call["name"], "args": call.get("args", {}), "id": call["id"]}
                for call in item.get("tool_calls", [])
            ],
            usage_metadata={
                "input_tokens": item.get("input_tokens", 0),
                "output_tokens": item.get("output_tokens", 0),
                "total_tokens": item.get("input_tokens", 0) + item.get("output_tokens", 0),
            },
        )

    raise BadCase(f"unknown reply type {kind!r}; expected 'reply' or 'structured'")


def discover(root: Path) -> list[Path]:
    return sorted(root.glob("*.json"))
