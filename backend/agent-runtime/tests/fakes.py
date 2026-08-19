"""A scripted stand-in for a chat model.

Duck-typed rather than a ``BaseChatModel`` subclass, deliberately. The runtime
uses exactly three things off a model — ``invoke``, ``bind_tools`` and
``with_structured_output`` — and a fake that implements only those documents
that surface precisely. Inheriting the real base class would drag in a pydantic
schema, a caching layer and a callback manager that the tests would then be
asserting against instead of against our own code.

The recorder half matters as much as the script half: :attr:`ScriptedModel.bound`
is how the narrowing tests prove that a mutating tool was never *offered* to a
read-only phase, rather than merely never called.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from langchain_core.messages import AIMessage


class ScriptExhausted(AssertionError):
    """The graph asked for one more model call than the test scripted.

    An assertion rather than a quiet ``None``: an extra call means the run took
    a path the test did not expect, and that is the finding.
    """


@dataclass
class Binding:
    """One ``bind_tools`` call, kept so a test can assert what was offered."""

    names: list[str]


@dataclass
class ScriptedModel:
    """Returns queued replies in order and records how it was called."""

    script: list[Any] = field(default_factory=list)

    #: Every ``bind_tools`` call, in order. The narrowing assertions read this.
    bound: list[Binding] = field(default_factory=list)
    #: Every message list this model was invoked with.
    seen: list[list[Any]] = field(default_factory=list)
    #: Phase tags off the run config, so a test can assert the phase sequence.
    phases: list[str] = field(default_factory=list)

    def _next(self, expect: type | None = None) -> Any:
        if not self.script:
            raise ScriptExhausted(
                f"The graph made more model calls than the script provides. "
                f"Phases so far: {self.phases}"
            )
        item = self.script.pop(0)
        if expect is not None and not isinstance(item, expect):
            raise AssertionError(
                f"Script expected a {expect.__name__} next, got {type(item).__name__}"
            )
        return item

    # -- the three methods the runtime actually uses -----------------------

    def invoke(self, messages: list[Any], config: dict | None = None) -> AIMessage:
        self.seen.append(messages)
        self._record_phase(config)
        return self._next(AIMessage)

    def bind_tools(self, tools: list[dict]) -> ScriptedModel:
        self.bound.append(Binding(names=[_name_of(tool) for tool in tools]))
        return self

    def with_structured_output(self, schema: type, include_raw: bool = False) -> _Structured:
        return _Structured(model=self, schema=schema, include_raw=include_raw)

    def _record_phase(self, config: dict | None) -> None:
        phase = ((config or {}).get("metadata") or {}).get("phase")
        if phase:
            self.phases.append(phase)


@dataclass
class _Structured:
    """What ``with_structured_output`` returns.

    Honours ``include_raw`` because the runtime relies on it to recover the
    token usage a structured call would otherwise throw away. A fake that
    ignored it would let a token-accounting regression pass.
    """

    model: ScriptedModel
    schema: type
    include_raw: bool = False

    def invoke(self, messages: list[Any], config: dict | None = None) -> Any:
        self.model.seen.append(messages)
        self.model._record_phase(config)
        parsed = self.model._next(self.schema)
        if not self.include_raw:
            return parsed
        return {
            "raw": AIMessage(
                content="",
                usage_metadata={"input_tokens": 40, "output_tokens": 20, "total_tokens": 60},
            ),
            "parsed": parsed,
            "parsing_error": None,
        }


def _name_of(tool: dict) -> str:
    """Reads the name back out of an OpenAI-format tool definition."""
    return (tool.get("function") or {}).get("name") or tool.get("name", "?")


def install(monkeypatch, model: ScriptedModel) -> ScriptedModel:
    """Points the runtime's model factory at a scripted model.

    Patches where the name is USED, not where it is defined — ``context.py``
    imported ``build_model`` by value, so patching ``models.build_model`` would
    leave the already-bound reference untouched and the test would silently
    talk to a real vendor.
    """
    monkeypatch.setattr(
        "agent_runtime.graph.context.build_model", lambda *args, **kwargs: model
    )
    return model


def reply(text: str = "", tool_calls: list[dict] | None = None) -> AIMessage:
    """An assistant turn, with usage metadata so token accounting is exercised."""
    return AIMessage(
        content=text,
        tool_calls=tool_calls or [],
        usage_metadata={"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
    )
