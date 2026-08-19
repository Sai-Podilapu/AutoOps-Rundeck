"""Building a chat model from a tenant's credentials, for exactly one call.

Mirrors ``modelsdk`` in agent-service, down to the credential key names —
``apiKey``, ``region``, ``endpoint`` — because those names are core-service's
catalog form fields and core is what sends them across. Two implementations of
the same mapping is a cost worth naming: the alternative is a shared schema
module both services depend on, and neither team wanted a build coupling
between a Java service and a Python one for eleven enum values that change
about once a year. :class:`~agent_runtime.app.state.Vendor` is where the
contract is enforced, and the tests pin it.

**Nothing is cached.** Not the client, not the credential. A cached client
outlives the key it was built with, survives a rotation the tenant believes
took effect immediately, and — the failure that actually matters — can serve
one tenant's agent from another tenant's key if the cache key is ever wrong.
The cost of rebuilding is microseconds against a call that is about to spend
seconds talking to a model.
"""

from __future__ import annotations

from typing import Any

from langchain_core.language_models import BaseChatModel
from langchain_core.utils.function_calling import convert_to_openai_tool

from agent_runtime.app.state import AgentDescriptor, ToolSpecWire, Vendor

#: Vendors that speak the OpenAI wire format on a fixed host. Mirrors the
#: ``baseUrl`` column of Java's ``ModelVendor``. This is a property of the
#: vendor, not a shortcut — their own documentation tells you to point an
#: OpenAI client at these hosts.
_OPENAI_COMPATIBLE: dict[Vendor, str | None] = {
    Vendor.OPENAI: None,
    Vendor.MISTRAL: "https://api.mistral.ai/v1",
    Vendor.GROQ: "https://api.groq.com/openai/v1",
    Vendor.DEEPSEEK: "https://api.deepseek.com/v1",
    Vendor.XAI: "https://api.x.ai/v1",
    Vendor.OLLAMA: None,  # the tenant's own host, read from credentials
}

#: Azure pins the API version per deployment and changes it often enough that
#: hard-coding one strands tenants on older resources. Overridable per tenant.
_AZURE_DEFAULT_API_VERSION = "2024-10-21"


class VendorNotRunnable(ValueError):
    """A vendor this runtime has no adapter for.

    Raised by name rather than resolved to something that happens to work.
    An agent configured for one vendor that quietly ran on another would bill
    the wrong account and send the tenant's data somewhere they did not choose,
    and it would do it silently.
    """


class MissingCredential(ValueError):
    """A credential field the vendor needs and the tenant has not supplied."""


def _require(credentials: dict[str, str], vendor: Vendor, key: str) -> str:
    value = (credentials.get(key) or "").strip()
    if not value:
        raise MissingCredential(f'{vendor.value} credentials are missing "{key}"')
    return value


def _require_url(credentials: dict[str, str], vendor: Vendor, key: str) -> str:
    return _require(credentials, vendor, key).rstrip("/")


def build_model(agent: AgentDescriptor, *, max_tokens: int | None = None) -> BaseChatModel:
    """A configured chat model for this agent, this tenant, this call."""
    vendor = agent.vendor
    credentials = agent.credentials
    tokens = max_tokens or agent.max_tokens

    if vendor is Vendor.ANTHROPIC:
        from langchain_anthropic import ChatAnthropic

        return ChatAnthropic(
            model=agent.model,
            api_key=_require(credentials, vendor, "apiKey"),
            max_tokens=tokens,
            timeout=120,
        )

    if vendor in _OPENAI_COMPATIBLE:
        from langchain_openai import ChatOpenAI

        if vendor is Vendor.OLLAMA:
            base_url = _require_url(credentials, vendor, "baseUrl") + "/v1"
            # Ollama ignores the key but the OpenAI client insists on one.
            api_key = (credentials.get("apiKey") or "").strip() or "ollama"
        else:
            base_url = _OPENAI_COMPATIBLE[vendor]
            api_key = _require(credentials, vendor, "apiKey")

        return ChatOpenAI(
            model=agent.model,
            api_key=api_key,
            base_url=base_url,
            max_tokens=tokens,
            timeout=120,
        )

    if vendor is Vendor.AZURE_OPENAI:
        from langchain_openai import AzureChatOpenAI

        return AzureChatOpenAI(
            # On Azure the "model" an agent names is the DEPLOYMENT name, not a
            # model id. Passing it as `model` reaches a resource that usually
            # does not exist and fails as a 404 several frames from the cause.
            azure_deployment=agent.model,
            azure_endpoint=_require_url(credentials, vendor, "endpoint"),
            api_key=_require(credentials, vendor, "apiKey"),
            api_version=(credentials.get("apiVersion") or "").strip()
            or _AZURE_DEFAULT_API_VERSION,
            max_tokens=tokens,
            timeout=120,
        )

    if vendor is Vendor.GOOGLE:
        from langchain_google_genai import ChatGoogleGenerativeAI

        return ChatGoogleGenerativeAI(
            model=agent.model,
            google_api_key=_require(credentials, vendor, "apiKey"),
            max_output_tokens=tokens,
            timeout=120,
        )

    if vendor is Vendor.BEDROCK:
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=agent.model,
            region_name=_require(credentials, vendor, "region"),
            aws_access_key_id=_require(credentials, vendor, "accessKeyId"),
            aws_secret_access_key=_require(credentials, vendor, "secretAccessKey"),
            max_tokens=tokens,
        )

    # HUAWEI reaches a ModelArts inference endpoint through Huawei's own SDK,
    # which has no LangChain adapter. agent-service still has a working Java
    # adapter for it, so `RuntimeClient.supports` keeps Huawei agents on the
    # legacy loop rather than letting them arrive here and fail. If one does
    # arrive, this refusal names the reason instead of producing a 500.
    raise VendorNotRunnable(
        f"{vendor.value} has no adapter in the Python runtime. Huawei-backed agents run "
        f"on the legacy loop; point this agent at an Anthropic, OpenAI, Azure, Google or "
        f"Bedrock connection to use the phased runtime."
    )


def is_runnable(vendor: Vendor) -> bool:
    """Whether :func:`build_model` can serve this vendor at all."""
    return vendor is not Vendor.HUAWEI


def to_openai_tools(specs: list[ToolSpecWire]) -> list[dict[str, Any]]:
    """Tool specs in the one shape every LangChain provider adapter accepts.

    Each provider's ``bind_tools`` converts onward from OpenAI's function
    format, so normalising here means the phase kit never branches on vendor.
    """
    tools: list[dict[str, Any]] = []
    for spec in specs:
        schema = dict(spec.input_schema or {})
        # A tool with no schema still needs a valid empty object one. Several
        # providers reject `parameters: {}` outright, and Anthropic in
        # particular requires the `type`/`properties` pair to be present.
        schema.setdefault("type", "object")
        schema.setdefault("properties", {})
        tools.append(
            convert_to_openai_tool(
                {
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": schema,
                }
            )
        )
    return tools
