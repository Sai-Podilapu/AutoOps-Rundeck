"""The wire contract between Java's control plane and this reducer.

Everything in this module is shared vocabulary. Java builds the request, stores
the returned ``state`` verbatim, and acts on the ``directive``; it never looks
inside the state. That opacity is the whole point of Factor 12 — the reducer
owns its own memory layout and can change it without a database migration,
provided it keeps honouring :data:`STATE_VERSION`.

Two rules govern every change to this file:

1. **The state must round-trip through JSON unchanged.** It is written to a
   MEDIUMTEXT column after every step and read back, possibly days later, quite
   possibly by a different instance of this service. Anything that does not
   survive ``model_dump_json`` -> ``model_validate_json`` does not belong here.
2. **A state written by an older version must never be silently misread.** A
   run parked on an approval on Friday can resume against a deployment that
   happened on Saturday. :func:`load_state` refuses a version it does not know
   rather than guessing, because a half-understood transcript is how an agent
   ends up repeating a destructive tool call it already made.
"""

from __future__ import annotations

import time
from enum import StrEnum
from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field

# Bump ONLY when an old state can no longer be read correctly. Adding an
# optional field with a default is not a bump; renaming or re-meaning one is.
STATE_VERSION = 1


class Vendor(StrEnum):
    """Mirrors ``ModelVendor`` in agent-service.

    The names must match exactly: Java sends the enum name as a string and this
    is where that contract is enforced. An unknown vendor is refused in
    :mod:`agent_runtime.app.models` rather than defaulted, because an agent
    configured for Bedrock that quietly ran on OpenAI would bill the wrong
    account and send the tenant's data to a vendor they did not choose.
    """

    OPENAI = "OPENAI"
    ANTHROPIC = "ANTHROPIC"
    GOOGLE = "GOOGLE"
    AZURE_OPENAI = "AZURE_OPENAI"
    BEDROCK = "BEDROCK"
    HUAWEI = "HUAWEI"
    MISTRAL = "MISTRAL"
    GROQ = "GROQ"
    DEEPSEEK = "DEEPSEEK"
    XAI = "XAI"
    OLLAMA = "OLLAMA"


class Phase(StrEnum):
    """Where a run is in its graph.

    Returned to Java on every reduce and surfaced in the run view, so an
    operator watching a long investigation sees "gathering evidence" rather
    than a spinner. Also the routing key inside the graph, which means the two
    cannot drift: the label the operator reads IS the node that is executing.
    """

    TRIAGE = "TRIAGE"
    GATHER = "GATHER"
    HYPOTHESIZE = "HYPOTHESIZE"
    PLAN = "PLAN"
    GATE = "GATE"
    ACT = "ACT"
    VERIFY = "VERIFY"
    REPORT = "REPORT"

    #: The un-phased loop, used only by the legacy compatibility agent. It sees
    #: every tool at once and enforces nothing, because it exists to reproduce
    #: what the Java loop does today for agents authored before this runtime.
    #: Deliberately absent from the phase kit's fall-through order so a phased
    #: agent can never land here and quietly acquire the full toolbox.
    RESPOND = "RESPOND"

    DONE = "DONE"


class Directive(StrEnum):
    """What Java must do next.

    Deliberately only three. The reducer decides *what should happen*; it has
    no vocabulary for *how* — no "park on approval", no "poll this run", no
    "record a step". Those are control-plane concerns and stay in Java, which
    is why asking for a tool that happens to need a human looks exactly like
    asking for one that does not.
    """

    CALL_TOOLS = "CALL_TOOLS"
    FINISH = "FINISH"
    FAIL = "FAIL"


# --------------------------------------------------------------- tools ---


class ToolSpecWire(BaseModel):
    """One entry of the agent's allow-list, as Java resolved it.

    ``mutating`` is computed on the Java side from the target's own metadata,
    never inferred here from the name or description. It is what lets a phase
    narrow its toolbox — :data:`Phase.GATHER` binds only the non-mutating
    entries — so a misclassification would hand a read-only phase something
    that changes state. It belongs with the service that knows the target.
    """

    name: str
    description: str
    input_schema: dict[str, Any] = Field(default_factory=dict)
    mutating: bool = False


class ToolCallWire(BaseModel):
    """A tool the model asked for.

    ``id`` is the vendor's correlation id, echoed back verbatim on the matching
    result. It is not ours to generate or normalise — Anthropic rejects a turn
    where any ``tool_use`` block lacks a ``tool_result`` carrying its exact id,
    and OpenAI behaves the same way.
    """

    id: str
    name: str
    arguments: dict[str, Any] = Field(default_factory=dict)


class ToolResultWire(BaseModel):
    """What a tool returned, and the audit row that proves it.

    ``evidence_id`` is the primary key of the ``agent_run_steps`` row Java
    already wrote for this result. That is the citation an operator can follow,
    and it is why the evidence ledger needs no table of its own: the ledger is
    an index over rows the control plane was writing anyway.

    It is optional only because a tool can fail before a step row exists. A
    result with no evidence id can still be reasoned about — it just cannot be
    cited, which is the correct outcome for something that did not produce an
    observation.
    """

    call_id: str
    ok: bool = True
    content: str = ""
    evidence_id: int | None = None

    #: Set when this result came back through the approvals inbox rather than
    #: straight from an automation.
    #:
    #: It rides on the result rather than arriving as its own event because a
    #: model can ask for several tools at once and every vendor requires them
    #: answered together — so the turn where a human rejected the second of
    #: three has to carry the other two results in the same breath. A separate
    #: event would have forced a choice between losing the decision and losing
    #: the results.
    decision: Literal["APPROVED", "REJECTED"] | None = None
    decided_by: str | None = None


# -------------------------------------------------------------- events ---


class StartEvent(BaseModel):
    kind: Literal["START"] = "START"
    input: str


class ToolResultsEvent(BaseModel):
    kind: Literal["TOOL_RESULTS"] = "TOOL_RESULTS"
    results: list[ToolResultWire] = Field(default_factory=list)


class HumanDecision(BaseModel):
    """A human's verdict, lifted off a result and onto the state.

    Kept as its own type rather than a bare boolean because the graph ROUTES on
    it: a rejection goes to REPORT to explain what was refused, never back to
    PLAN to look for a different way in. A run that reroutes around a human's
    "no" is the single worst behaviour an operations agent can have, and having
    the verdict as a first-class piece of state is what makes that routing
    explicit rather than a prompt instruction.
    """

    approved: bool
    decided_by: str | None = None
    content: str = ""
    call_id: str | None = None


Event = Annotated[
    StartEvent | ToolResultsEvent,
    Field(discriminator="kind"),
]


# --------------------------------------------------------------- state ---


class Message(BaseModel):
    """One conversation turn, in a shape no vendor uses.

    Mirrors Java's ``ChatMessage`` on purpose: the vendors disagree about how a
    tool exchange is represented, and modelling either shape here would make
    the other adapter a translation of a translation. ``tool_results`` is a
    LIST because Anthropic requires every result for a turn in one message —
    a shape that can only express one at a time makes that impossible to emit.
    """

    role: Literal["user", "assistant", "tool_results"]
    text: str = ""
    tool_calls: list[ToolCallWire] = Field(default_factory=list)
    tool_results: list[ToolResultWire] = Field(default_factory=list)


class Evidence(BaseModel):
    """One observation the agent is allowed to assert.

    ``digest`` is a hash of the content at the moment it was recorded. Nothing
    reads it today; it exists so that a stored transcript can later be checked
    against the step row it claims to cite, and a divergence surfaced rather
    than trusted.
    """

    evidence_id: int
    tool: str
    ok: bool
    excerpt: str
    digest: str
    phase: Phase
    recorded_at: float = Field(default_factory=time.time)


class Finding(BaseModel):
    """Something the agent concluded, and what it concluded it from.

    ``cites`` is required and may not be empty — a finding with no evidence is
    a guess, and the point of this runtime is that guesses are visible as such.
    """

    summary: str
    severity: Literal["info", "warning", "critical", "unknown"] = "info"
    cites: list[int] = Field(default_factory=list)


class PlannedAction(BaseModel):
    """A state-changing step the agent wants to take.

    Carried through the state even though the typed change-plan UI is deferred:
    the gate needs *something* structured to hand a human, and writing it now
    means the approval screen is a rendering job later rather than a redesign.
    """

    tool: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    intent: str = ""
    blast_radius: str = ""
    rollback: str = ""
    cites: list[int] = Field(default_factory=list)


class AgentState(BaseModel):
    """Everything the reducer knows. Persisted by Java, opaque to Java.

    This is the run. There is no other copy — no in-memory session, no cache
    keyed by run id, nothing on the stack. A reduce call rebuilds the entire
    world from this object, does the smallest amount of work that reaches the
    next boundary, and hands back a new one. That is what makes a run parked
    for two days indistinguishable from a run parked for two milliseconds.
    """

    version: int = STATE_VERSION

    agent_ref: str
    input: str
    phase: Phase = Phase.TRIAGE

    messages: list[Message] = Field(default_factory=list)
    ledger: list[Evidence] = Field(default_factory=list)
    findings: list[Finding] = Field(default_factory=list)
    planned: list[PlannedAction] = Field(default_factory=list)

    pending_tool_calls: list[ToolCallWire] = Field(default_factory=list)

    # How many times each phase has executed. The bound on the gather ->
    # hypothesize -> gather cycle lives here rather than on the step budget
    # because Java's budget counts model calls across the whole run: a graph
    # that oscillates would exhaust it and report "out of steps" instead of
    # the far more useful "I could not narrow this down".
    phase_visits: dict[str, int] = Field(default_factory=dict)

    # Set when the report shipped with claims the ledger could not support.
    # Surfaced to the operator verbatim; never used to fail the run, because a
    # flagged report is still worth more than no report.
    uncited_claims: list[str] = Field(default_factory=list)

    human_decision: HumanDecision | None = None
    last_error: str | None = None

    def visit(self, phase: Phase) -> int:
        """Records an entry into a phase and returns the new count."""
        count = self.phase_visits.get(phase.value, 0) + 1
        self.phase_visits[phase.value] = count
        return count

    def visits(self, phase: Phase) -> int:
        return self.phase_visits.get(phase.value, 0)

    def cited(self) -> set[int]:
        return {entry.evidence_id for entry in self.ledger}


class StateVersionError(ValueError):
    """A stored state this build cannot read."""


def load_state(raw: dict[str, Any] | None) -> AgentState | None:
    """Rehydrates a state Java handed back, or refuses it.

    Refusing is the whole job. A state from a future version means a rollback
    happened underneath a parked run; a state from a past version means an
    upgrade did. Either way the safe answer is to fail the run loudly and leave
    the approval sitting in the inbox, because the alternative — reading a
    transcript whose fields mean something slightly different now — produces an
    agent that believes it has not yet done something it has already done.
    """
    if raw is None:
        return None
    version = raw.get("version")
    if version != STATE_VERSION:
        raise StateVersionError(
            f"This run's saved state is version {version}, and this runtime writes "
            f"version {STATE_VERSION}. It cannot be resumed safely. Start a new run; "
            f"any approval it raised is still in the inbox."
        )
    return AgentState.model_validate(raw)


# ------------------------------------------------------------ envelope ---


class AgentDescriptor(BaseModel):
    """Which agent to run, and what to run it with.

    ``instructions`` is populated only for the legacy JSON path, where the
    persona still lives in the tenant's own row. Python-authored agents leave
    it empty and carry their prompts in this service's image, which is what
    makes them genuinely unreadable to the customer rather than merely
    un-exposed by an API.
    """

    #: Which module in the registry runs this agent, or NULL for a JSON-persona
    #: agent that has no graph of its own.
    #:
    #: Nullable on purpose, and it has to be: agent-service sends null for
    #: every agent whose `graph_ref` column is unset, which is the ordinary
    #: case for one a customer built. :func:`agents.resolve` already maps None
    #: onto the single-phase compatibility agent — declaring this required
    #: rejected the request before it ever got there, with a 422 that said
    #: nothing about which agent or why.
    ref: str | None = None
    version: str | None = None
    model: str
    vendor: Vendor
    credentials: dict[str, str] = Field(default_factory=dict, repr=False)
    params: dict[str, Any] = Field(default_factory=dict)
    instructions: str | None = Field(default=None, repr=False)
    max_tokens: int = 4096

    def __str__(self) -> str:  # pragma: no cover - diagnostics only
        return f"AgentDescriptor(ref={self.ref!r}, version={self.version!r}, model={self.model!r})"


class ReduceRequest(BaseModel):
    agent: AgentDescriptor
    tools: list[ToolSpecWire] = Field(default_factory=list)
    state: dict[str, Any] | None = None
    event: Event
    # Correlation only — this service stores nothing keyed by them. They exist
    # so a Langfuse trace can be found from a run id and vice versa.
    run_id: int | None = None
    tenant_id: str | None = None
    # Tools the allow-list named but Java could not offer. Named in the prompt
    # rather than omitted silently: an agent whose only relevant tool was
    # deleted should say "I cannot do that any more", not quietly do something
    # else instead.
    unavailable: list[str] = Field(default_factory=list)


class Usage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0


class ReduceResponse(BaseModel):
    state: dict[str, Any]
    phase: Phase
    directive: Directive
    tool_calls: list[ToolCallWire] = Field(default_factory=list)
    output: str | None = None
    error: str | None = None
    usage: Usage = Field(default_factory=Usage)
    trace_id: str | None = None
    # Stamped on the run so a resume can tell, without parsing the state, which
    # build wrote it.
    state_version: int = STATE_VERSION
    #: Model calls made during THIS reduce. agent-service adds it to the run's
    #: step count rather than incrementing by one, because a single reduce can
    #: span several phases — and a budget that counts reduces would let a
    #: phased agent make several times the allowance it was given.
    model_calls: int = 0
    # Citations the report actually used, so Java can check every one against
    # this run's own step ids. The second of the two independent layers: even
    # if this service's own enforcement is wrong, an id that was never issued
    # for this run cannot survive.
    citations: list[int] = Field(default_factory=list)
    uncited_claims: list[str] = Field(default_factory=list)
