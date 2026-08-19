"""Which tools a phase is allowed to see.

The allow-list itself is decided in Java — ``AgentToolbox.resolve`` is the only
thing that turns a tool name into a real target, and it answers only from this
agent's own grant. Nothing here can widen that. What this module does is
*narrow* it per phase, which is Factor 10 applied inside a single run: the
evidence-gathering phase is not merely instructed to avoid destructive tools,
it is never shown one.

That distinction matters more than it sounds. A model that can see a delete
tool while it is diagnosing will eventually reach for it — not through
malice but because the tool is right there and looks like progress. Removing
it from the request is the only version of "don't do that" a model cannot
misread, forget twelve turns later, or be talked out of by a user who insists.

:meth:`Toolbox.check` is the belt to that braces: even if a model returns a
name it was never offered — hallucinated, remembered from a previous run,
copied from its training data — the call is refused with an error it can act
on rather than dispatched.
"""

from __future__ import annotations

from dataclasses import dataclass

from agent_runtime.app.state import Phase, ToolCallWire, ToolSpecWire


class Access:
    """What a phase may reach for."""

    NONE = "none"
    READ_ONLY = "read-only"
    MUTATING = "mutating"


#: The table is the policy. Keeping it as data rather than scattering
#: conditionals through the phase implementations means the answer to "could
#: this agent have deleted something while it was still diagnosing?" is one
#: place to look, and one place to change.
PHASE_ACCESS: dict[Phase, str] = {
    Phase.TRIAGE: Access.NONE,
    Phase.GATHER: Access.READ_ONLY,
    Phase.HYPOTHESIZE: Access.NONE,
    Phase.PLAN: Access.NONE,
    Phase.GATE: Access.MUTATING,
    Phase.ACT: Access.MUTATING,
    Phase.VERIFY: Access.READ_ONLY,
    Phase.REPORT: Access.NONE,
    # The legacy loop. Everything at once, which is exactly today's behaviour
    # and exactly what the phased agents exist to improve on.
    Phase.RESPOND: Access.MUTATING,
    Phase.DONE: Access.NONE,
}


@dataclass(frozen=True)
class Toolbox:
    """The agent's full grant, and the phase-narrowed views onto it."""

    specs: list[ToolSpecWire]
    unavailable: list[str]

    def for_phase(self, phase: Phase) -> list[ToolSpecWire]:
        access = PHASE_ACCESS.get(phase, Access.NONE)
        if access == Access.NONE:
            return []
        if access == Access.READ_ONLY:
            return [spec for spec in self.specs if not spec.mutating]
        # MUTATING phases keep the read-only tools too: an action phase
        # routinely needs to look something up to build its arguments, and
        # forcing it back through GATHER for that would cost a full round trip
        # to learn a volume id it is about to pass to a tool it already holds.
        return list(self.specs)

    def names_for_phase(self, phase: Phase) -> set[str]:
        return {spec.name for spec in self.for_phase(phase)}

    def check(self, phase: Phase, call: ToolCallWire) -> str | None:
        """Why this call is not allowed here, or ``None`` if it is.

        Returns a message written for the MODEL, not for a log. It names what
        it may use instead, because a refusal that does not say what would have
        worked just produces the same call again next turn.
        """
        allowed = self.names_for_phase(phase)
        if call.name in allowed:
            return None

        known = {spec.name for spec in self.specs}
        if call.name not in known:
            offered = ", ".join(sorted(allowed)) or "none in this phase"
            return (
                f'There is no tool called "{call.name}". Available here: {offered}.'
            )

        # The tool exists but not in this phase. Almost always a mutating tool
        # reached for while gathering evidence, and the model needs to know the
        # route to it rather than just that the door is shut.
        return (
            f'"{call.name}" changes state, so it cannot be called while you are still '
            f"gathering evidence. Finish your assessment and propose it as an action; "
            f"it will be put to a human for approval."
        )

    def has_mutating(self) -> bool:
        return any(spec.mutating for spec in self.specs)

    def is_empty(self) -> bool:
        return not self.specs
