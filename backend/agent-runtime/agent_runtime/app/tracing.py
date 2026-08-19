"""Langfuse tracing, and what happens when it is not there.

Every model call this service makes is traced with the phase it belongs to, the
prompt version that produced it, and the agent ref and version. That is what
turns "the agent said something odd on Tuesday" into a specific node, a specific
prompt revision and a specific set of observations.

**Tracing never fails a run.** If Langfuse is unconfigured, unreachable, or
throws while building a handler, this returns no callbacks and the run proceeds
untraced. An observability dependency that can take down the thing it observes
is worse than no observability — and this particular thing runs automations
against customer infrastructure.
"""

from __future__ import annotations

import logging
from typing import Any

from agent_runtime.app.config import settings
from agent_runtime.app.state import AgentDescriptor
from agent_runtime.graph.prompts import PROMPT_VERSION

log = logging.getLogger(__name__)


def handlers(
    agent: AgentDescriptor,
    *,
    run_id: int | None,
    tenant_id: str | None,
) -> tuple[list[Any], str | None]:
    """Callback handlers for one reduce, and the trace id they will write to."""
    config = settings()
    if not config.langfuse_enabled:
        return [], None
    if not (config.langfuse_public_key and config.langfuse_secret_key):
        log.warning("Langfuse is enabled but its keys are unset; running untraced.")
        return [], None

    try:
        from langfuse.callback import CallbackHandler

        # One trace per RUN, not per reduce. A run that parks on an approval
        # for two days produces several reduces, and they belong on the same
        # trace — otherwise the interesting artefact (an investigation that
        # stopped for a human and then resumed) is scattered across unrelated
        # traces nobody can reassemble.
        trace_id = f"agent-run-{run_id}" if run_id else None

        handler = CallbackHandler(
            public_key=config.langfuse_public_key,
            secret_key=config.langfuse_secret_key,
            host=config.langfuse_host,
            session_id=trace_id,
            user_id=tenant_id,
            tags=[
                f"agent:{agent.ref}",
                f"agent_version:{agent.version or 'unversioned'}",
                f"prompts:{PROMPT_VERSION}",
                f"vendor:{agent.vendor.value}",
            ],
            metadata={
                "agent_ref": agent.ref,
                "agent_version": agent.version,
                "prompt_version": PROMPT_VERSION,
                "model": agent.model,
                "vendor": agent.vendor.value,
                "run_id": run_id,
                "tenant_id": tenant_id,
            },
        )
        return [handler], trace_id
    except Exception as exc:  # noqa: BLE001 - see the module docstring
        log.warning("Tracing unavailable, running untraced: %s", exc)
        return [], None
