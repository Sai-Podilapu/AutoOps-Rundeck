"""The compatibility agent: what runs when nobody has authored a Python module.

agent-service holds agents that are JSON — a persona, a model and an allow-list
— and they work. Turning this runtime on must not change what any of them do.
So an agent with no ``graph_ref`` resolves here, and this graph reproduces the
existing Java loop exactly: one node, every tool bound at once, the full
transcript, no phase narrowing and no evidence enforcement.

That last part is worth being explicit about rather than quietly improving. A
legacy agent's prompt was written for a loop with no citation rule; switching
one on underneath it would produce reports full of ``[e:..]`` markers its
persona never accounted for, and the honest reading of "nothing that runs today
stops running" is that its OUTPUT should not change either.

An agent gets the phased runtime by being rewritten as a module, deliberately,
by whoever owns it. Not by being redeployed.
"""

from __future__ import annotations

from langgraph.graph import END, START, StateGraph

from agent_runtime.agents.spec import AgentSpec, Manifest
from agent_runtime.app.state import Phase
from agent_runtime.graph import phases
from agent_runtime.graph.phases import GraphState

REF = "generic.single_phase"


def _build():
    """One node, and an edge that stops as soon as it wants a tool."""
    graph: StateGraph = StateGraph(GraphState)
    graph.add_node(Phase.RESPOND.value, phases.respond)
    graph.add_edge(START, Phase.RESPOND.value)
    # Unconditional. The node either parks holding tool calls or sets DONE, and
    # in both cases this reduce is over — the next model call is the next
    # reduce, driven by Java, which is what keeps the loop's control flow on
    # the side that owns the approvals and the audit rows.
    graph.add_edge(Phase.RESPOND.value, END)
    return graph.compile()


MANIFEST = Manifest(
    ref=REF,
    version="1.0.0",
    name="Single-phase agent",
    description=(
        "The un-phased loop used by agents whose definition is a JSON persona rather than a "
        "Python module. Reproduces the original agent loop exactly."
    ),
    domain="Generic",
    # Overridden per run by whatever the agent's own row says; this is only a
    # placeholder so the manifest is complete. Nothing publishes this agent to
    # the catalog — it is a runtime fallback, not a product.
    model="anthropic.claude-sonnet-5",
    guardrails=[
        "Tool access is the agent's own allow-list, enforced by agent-service.",
        "No phase narrowing and no evidence enforcement — matches the legacy loop.",
    ],
)

#: ``persona`` is empty on purpose: the legacy agent's instructions arrive per
#: run on the descriptor, out of the tenant's own row, and are injected there.
AGENT = AgentSpec(
    manifest=MANIFEST,
    persona="",
    build_graph=_build,
    phases=(Phase.RESPOND,),
)
