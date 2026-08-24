"""Service settings. Environment only — this service reads no config file.

It holds no state and no credentials of its own: the tenant's model key arrives
per request and leaves with it. What is here is the shared secret its own
``/v1`` endpoints require, and the tracing connection.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict

DEV_INTERNAL_TOKEN = "dev-internal-token"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="AGENT_RUNTIME_", case_sensitive=False)

    #: Shared secret required on every ``/v1`` call, matching the
    #: ``X-Internal-Token`` pattern the Java services already use between
    #: themselves. There is no user-facing auth here because there is no
    #: user-facing route: the gateway does not expose this service at all.
    internal_token: str = DEV_INTERNAL_TOKEN

    #: Ceiling on ONE model reply. A per-run budget is Java's job — it owns the
    #: step count — and duplicating it here would give two answers to "why did
    #: this stop".
    max_tokens: int = 4096

    langfuse_enabled: bool = False
    langfuse_host: str = "http://langfuse:3000"
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""

    #: Bounds a FAILED tool result before it enters the transcript. Factor 9: a
    #: 40,000-line stack trace teaches a model nothing that its first and last
    #: twenty lines do not, and it crowds out the evidence that would have let
    #: it recover.
    error_excerpt_limit: int = 2000

    #: Bounds a SUCCESSFUL one, and is deliberately far larger.
    #:
    #: The two were one setting, and that was wrong. A failed step's output is
    #: noise to be summarised; a successful step's output is frequently the
    #: DELIVERABLE. A research workflow returned a 50,000-character report and
    #: it was cut to 2,000 before the model ever saw it — the agent was then
    #: asked to hand back a report it had only been shown the first page of.
    #:
    #: Still bounded, because an unbounded result is a context-window overflow
    #: waiting to happen. Raise it if your automations legitimately return more.
    output_limit: int = 120000


@lru_cache(maxsize=1)
def settings() -> Settings:
    return Settings()
