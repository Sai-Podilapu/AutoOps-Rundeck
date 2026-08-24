"""``(state, event) -> state'`` — the whole service, in one function.

Factor 12, taken literally. :func:`reduce` holds nothing between calls: it
rebuilds the agent, the toolbox, the model client and the graph from the request
it was handed, advances the run to its next boundary, and returns. Two
consecutive calls could land on two different instances, or on the same instance
three days apart across a redeploy, and neither case is special-cased because
neither case is different.

What makes that affordable is that the boundaries are cheap and few. A run stops
when it wants a tool — which Java must execute anyway, because Java owns
approvals and audit — or when it is finished. Everything between those points is
one graph traversal, and nothing in it needs to survive.

The other half of the contract is error handling. A reduce that raises produces a
500 and a run that Java has to guess about; a reduce that returns
:data:`~agent_runtime.app.state.Directive.FAIL` produces a run that fails with a
sentence an operator can act on. So the only exceptions that escape this module
are the ones that mean the request itself was malformed.
"""

from __future__ import annotations

import logging

from agent_runtime import agents
from agent_runtime.app import evidence, tracing
from agent_runtime.app.config import settings
from agent_runtime.app.models import MissingCredential, VendorNotRunnable
from agent_runtime.app.state import (
    AgentState,
    Directive,
    HumanDecision,
    Message,
    Phase,
    ReduceRequest,
    ReduceResponse,
    StartEvent,
    StateVersionError,
    ToolResultsEvent,
    ToolResultWire,
    Usage,
    load_state,
)
from agent_runtime.app.toolbox import Toolbox
from agent_runtime.graph.context import RunContext

log = logging.getLogger(__name__)


def reduce(request: ReduceRequest) -> ReduceResponse:
    """Advances one run by one boundary."""
    try:
        resolution = agents.resolve(request.agent.ref, request.agent.version)
    except agents.UnknownAgent as exc:
        return _fail(None, str(exc))

    spec = resolution.spec

    try:
        state = _apply(request, spec.ref)
    except StateVersionError as exc:
        return _fail(None, str(exc))

    toolbox = Toolbox(specs=list(request.tools), unavailable=list(request.unavailable))
    callbacks, trace_id = tracing.handlers(
        request.agent, run_id=request.run_id, tenant_id=request.tenant_id
    )

    context = RunContext(
        agent=request.agent.model_copy(update={"max_tokens": settings().max_tokens}),
        toolbox=toolbox,
        # A Python-authored agent's voice comes from this image. A legacy JSON
        # agent's comes from the tenant's row, on the descriptor. Exactly one
        # of the two is ever populated.
        persona=spec.persona or (request.agent.instructions or ""),
        callbacks=callbacks,
        trace_id=trace_id,
    )

    try:
        graph = spec.build_graph()
        result = graph.invoke({"state": state, "ctx": context})
        state = result["state"]
    except (VendorNotRunnable, MissingCredential) as exc:
        # A configuration problem, not a run problem. The message names the
        # vendor and the field, which is what sends the operator to the right
        # screen instead of to the run log.
        return _fail(state, str(exc), context=context, trace_id=trace_id)
    except Exception as exc:  # noqa: BLE001 - see the module docstring
        log.exception("Agent %s failed while reducing run %s", spec.ref, request.run_id)
        return _fail(
            state,
            f"The agent stopped unexpectedly: {type(exc).__name__}: {exc}",
            context=context,
            trace_id=trace_id,
        )

    return _respond(state, context, resolution, trace_id)


# --------------------------------------------------------------- events ---


def _apply(request: ReduceRequest, agent_ref: str) -> AgentState:
    """Folds the incoming event into the state, or starts a new one."""
    event = request.event

    if isinstance(event, StartEvent):
        # A START against an existing state would silently discard a run's
        # history — including tool calls that already executed. Java only ever
        # sends START with a null state, and if that ever stops being true the
        # right answer is to notice, not to reset.
        if request.state is not None:
            raise StateVersionError(
                "A START event arrived for a run that already has saved state. This run "
                "cannot be restarted in place; start a new one."
            )
        return AgentState(agent_ref=agent_ref, input=event.input)

    state = load_state(request.state)
    if state is None:
        raise StateVersionError(
            "This run has no saved state, so there is nothing to resume. Start a new run."
        )

    if isinstance(event, ToolResultsEvent):
        _absorb(state, event.results)

    return state


def _absorb(state: AgentState, results: list[ToolResultWire]) -> None:
    """Files results onto the transcript and into the ledger.

    Order matters: the transcript entry is written first because
    :func:`evidence.record` reads it back to work out which tool produced each
    result — Java sends results keyed by call id and does not repeat the name.
    """
    compacted = [
        result.model_copy(update={"content": _compact(state, result)}) for result in results
    ]
    state.messages.append(Message(role="tool_results", tool_results=compacted))
    state.pending_tool_calls = []
    evidence.record(state, compacted, state.phase)

    # A human's verdict rides in on a result but belongs on the state, because
    # the graph routes on it. The LAST decision in the turn wins: a turn can
    # only ever park on one approval at a time, so there is at most one.
    for result in compacted:
        if result.decision is not None:
            state.human_decision = HumanDecision(
                approved=result.decision == "APPROVED",
                decided_by=result.decided_by,
                content=result.content,
                call_id=result.call_id,
            )


def _compact(state: AgentState, result: ToolResultWire) -> str:
    """Factor 9: bound one result, and say when it has happened before.

    Two problems, one place. A 40,000-line log crowds out the evidence that
    would let the model recover, so it is elided from the middle — the head
    carries the command and the tail carries the failure, and the interesting
    parts of a log are almost never in between.

    The repeat counter addresses the other failure mode. A model that gets the
    same error twice will often try a third time, because nothing in its
    context distinguishes attempt three from attempt one. Saying so plainly is
    what breaks the loop — and it is a fact, not a nudge.
    """
    content = result.content or ""
    # A failure is summarised hard; a success is the deliverable and is kept.
    limit = settings().error_excerpt_limit if not result.ok else settings().output_limit

    if len(content) > limit:
        head = content[: limit // 2].rstrip()
        tail = content[-(limit // 2) :].lstrip()
        elided = len(content) - len(head) - len(tail)
        content = f"{head}\n\n... [{elided} characters elided] ...\n\n{tail}"

    if result.ok:
        return content

    seen = sum(
        1
        for message in state.messages
        for previous in message.tool_results
        if not previous.ok and _same_failure(previous.content, content)
    )
    if seen:
        content += (
            f"\n\n[This same failure has now occurred {seen + 1} times in this run. "
            f"Repeating the call will not change it — either change the approach or "
            f"report that it cannot be done.]"
        )
    return content


def _same_failure(left: str, right: str) -> bool:
    """Whether two errors are the same one again.

    Compares the first line only. Errors routinely carry a timestamp, a request
    id or a duration that differs on every attempt, and a whole-string
    comparison would call every retry a new problem — which is precisely the
    case the counter exists to catch.
    """
    return (left or "").strip().splitlines()[:1] == (right or "").strip().splitlines()[:1]


# -------------------------------------------------------------- replies ---


def _respond(
    state: AgentState,
    context: RunContext,
    resolution: agents.Resolution,
    trace_id: str | None,
) -> ReduceResponse:
    """Turns the state the graph left behind into a directive for Java."""
    if state.pending_tool_calls:
        return ReduceResponse(
            state=state.model_dump(mode="json"),
            phase=state.phase,
            directive=Directive.CALL_TOOLS,
            tool_calls=list(state.pending_tool_calls),
            usage=context.usage,
            model_calls=context.calls,
            trace_id=trace_id,
        )

    output = _final_text(state)

    if state.phase is not Phase.DONE:
        # The graph ran out of nodes without reaching REPORT. That is a routing
        # bug, and it is reported as one rather than dressed up as a finished
        # run — a run that "succeeded" with no report is the kind of thing
        # nobody investigates until it has happened a hundred times.
        return _fail(
            state,
            f"The agent stopped in phase {state.phase.value} without producing a report.",
            context=context,
            trace_id=trace_id,
        )

    note = resolution.note
    if note:
        # Prepended, not appended: it is a caveat about the whole report and
        # belongs where it will be read.
        output = f"_{note}_\n\n{output}" if output else note

    return ReduceResponse(
        state=state.model_dump(mode="json"),
        phase=Phase.DONE,
        directive=Directive.FINISH,
        output=output,
        usage=context.usage,
        model_calls=context.calls,
        trace_id=trace_id,
        citations=evidence.parse_citations(output or ""),
        uncited_claims=list(state.uncited_claims),
    )


def _final_text(state: AgentState) -> str:
    for message in reversed(state.messages):
        if message.role == "assistant" and message.text.strip():
            return message.text
    return ""


def _fail(
    state: AgentState | None,
    message: str,
    *,
    context: RunContext | None = None,
    trace_id: str | None = None,
) -> ReduceResponse:
    """A failure Java can record and an operator can read.

    The state is still returned when there is one. A run that failed halfway
    through an investigation did real work — tool calls that executed, evidence
    that was collected — and discarding it would leave the operator with an
    error and no account of what had already happened to their systems.
    """
    if state is not None:
        state.last_error = message
    return ReduceResponse(
        state=state.model_dump(mode="json") if state is not None else {},
        phase=state.phase if state is not None else Phase.TRIAGE,
        directive=Directive.FAIL,
        error=message,
        output=_final_text(state) if state is not None else None,
        # Tokens already spent are still billable and still worth reporting,
        # even on the call that failed.
        usage=context.usage if context is not None else Usage(),
        model_calls=context.calls if context is not None else 0,
        trace_id=trace_id,
    )
