"""Bedrock boto3 config — proxy via BEDROCK_ENDPOINT_URL with upstream SigV4 signing."""

import logging
import os
from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

from botocore.config import Config
from dotenv import load_dotenv
from langchain_aws import ChatBedrock, ChatBedrockConverse

load_dotenv()


def _prefer_sigv4_over_bearer() -> None:
    """boto3 prefers Bearer API keys over SigV4 when both are set."""
    if os.getenv("BEDROCK_USE_BEARER", "").strip().lower() in ("1", "true", "yes"):
        return
    if os.getenv("AWS_PROFILE", "").strip() or os.getenv("AWS_ACCESS_KEY_ID", "").strip():
        os.environ.pop("AWS_BEARER_TOKEN_BEDROCK", None)


_prefer_sigv4_over_bearer()

logger = logging.getLogger(__name__)

BedrockApi = Literal["invoke", "converse"]

DEFAULT_REGION = "us-east-1"
DEFAULT_MODEL_CONVERSE = "amazon.nova-micro-v1:0"
DEFAULT_MODEL_INVOKE = "anthropic.claude-3-sonnet-20240229-v1:0"
DEFAULT_LLM_TIMEOUT_SECONDS = 90.0
DEFAULT_MAX_TOKENS = 256

# Akto routing params — signed out of the Bedrock request, re-added on the wire for proxy routing.
ROUTING_QUERY_PARAMS = frozenset({"openai_url", "upstream_url"})

BEDROCK_RUNTIME_OPERATIONS = (
    "Converse",
    "ConverseStream",
    "InvokeModel",
    "InvokeModelWithResponseStream",
)


@dataclass(frozen=True)
class ProxySigningConfig:
    signing_host: str
    wire_host: str
    routing_query: str


def bedrock_api() -> BedrockApi:
    raw = os.getenv("BEDROCK_API", "converse").strip().lower()
    if raw == "invoke":
        return "invoke"
    return "converse"


def default_model_id() -> str:
    explicit = os.getenv("BEDROCK_MODEL_ID", "").strip()
    if explicit:
        return explicit
    if bedrock_api() == "converse":
        return DEFAULT_MODEL_CONVERSE
    return DEFAULT_MODEL_INVOKE


def resolve_endpoint_url() -> str | None:
    """Client proxy integration: set BEDROCK_ENDPOINT_URL (boto3 endpoint_url)."""
    url = os.getenv("BEDROCK_ENDPOINT_URL", "").strip()
    return url or None


def bedrock_auth_mode() -> Literal["sigv4", "bearer"]:
    if os.getenv("AWS_BEARER_TOKEN_BEDROCK", "").strip():
        return "bearer"
    return "sigv4"


def _default_signing_host() -> str:
    region = os.getenv("AWS_REGION", DEFAULT_REGION)
    return f"bedrock-runtime.{region}.amazonaws.com"


def resolve_proxy_signing_config() -> ProxySigningConfig | None:
    """
    When using an Akto proxy, sign as Bedrock will see the forwarded request:
    - Host = upstream Bedrock runtime host (from openai_url or BEDROCK_SIGNING_HOST)
    - Canonical query excludes routing params (openai_url); those are re-added after signing
    """
    endpoint = resolve_endpoint_url()
    if not endpoint:
        return None

    explicit_host = os.getenv("BEDROCK_SIGNING_HOST", "").strip()
    parsed = urlparse(endpoint)
    routing_query = parsed.query

    if explicit_host:
        signing_host = explicit_host
    elif routing_query:
        qs = parse_qs(routing_query)
        signing_host = _default_signing_host()
        for key in ("openai_url", "upstream_url"):
            values = qs.get(key)
            if not values:
                continue
            upstream = urlparse(values[0])
            if upstream.hostname:
                signing_host = upstream.hostname
                break
    else:
        signing_host = _default_signing_host()

    wire_host = parsed.hostname or signing_host
    return ProxySigningConfig(
        signing_host=signing_host,
        wire_host=wire_host,
        routing_query=routing_query,
    )


def resolve_signing_host() -> str | None:
    config = resolve_proxy_signing_config()
    return config.signing_host if config else None


def _strip_routing_query_from_url(url: str) -> str:
    parts = urlparse(url)
    if not parts.query:
        return url

    qs = parse_qs(parts.query, keep_blank_values=True)
    filtered = [
        (key, value)
        for key, values in qs.items()
        if key not in ROUTING_QUERY_PARAMS
        for value in values
    ]
    new_query = urlencode(filtered, doseq=True) if filtered else ""
    return urlunparse(parts._replace(query=new_query))


def _ensure_routing_query_on_url(url: str, routing_query: str) -> str:
    if not routing_query:
        return url

    parts = urlparse(url)
    merged = parse_qs(parts.query, keep_blank_values=True)
    for key, values in parse_qs(routing_query, keep_blank_values=True).items():
        if key not in merged:
            merged[key] = values

    flat = [(key, value) for key, values in merged.items() for value in values]
    return urlunparse(parts._replace(query=urlencode(flat, doseq=True)))


def install_proxy_sigv4_signing(client: Any, config: ProxySigningConfig) -> None:
    """Sign the Bedrock-bound request; route the signed bytes through the Akto proxy."""

    def _before_sign(request: Any, **kwargs: Any) -> None:
        request.headers["Host"] = config.signing_host
        if hasattr(request, "url"):
            request.url = _strip_routing_query_from_url(request.url)

    def _before_send(request: Any, **kwargs: Any) -> None:
        # App gateway routes on proxy Host; Akto rewrites to signing_host when forwarding.
        request.headers["Host"] = config.wire_host
        if hasattr(request, "url") and config.routing_query:
            request.url = _ensure_routing_query_on_url(request.url, config.routing_query)

    for operation in BEDROCK_RUNTIME_OPERATIONS:
        client.meta.events.register_first(
            f"before-sign.bedrock-runtime.{operation}",
            _before_sign,
        )
        client.meta.events.register_first(
            f"before-send.bedrock-runtime.{operation}",
            _before_send,
        )


def _llm_timeout_seconds() -> float:
    raw = os.getenv("LLM_TIMEOUT_SECONDS")
    if raw is None:
        return DEFAULT_LLM_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_LLM_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_LLM_TIMEOUT_SECONDS


def _max_tokens() -> int:
    raw = os.getenv("BEDROCK_MAX_TOKENS")
    if raw is None:
        return DEFAULT_MAX_TOKENS
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_MAX_TOKENS
    return value if value > 0 else DEFAULT_MAX_TOKENS


def _base_llm_kwargs(model_id: str | None = None) -> dict[str, Any]:
    model = model_id or default_model_id()
    region = os.getenv("AWS_REGION", DEFAULT_REGION)
    endpoint_url = resolve_endpoint_url()

    config = Config(
        connect_timeout=_llm_timeout_seconds(),
        read_timeout=_llm_timeout_seconds(),
        retries={"max_attempts": 0},
    )

    kwargs: dict[str, Any] = {
        "model_id": model,
        "region_name": region,
        "temperature": 0,
        "max_tokens": _max_tokens(),
        "config": config,
    }
    if endpoint_url:
        kwargs["endpoint_url"] = endpoint_url

    profile = os.getenv("AWS_PROFILE", "").strip()
    if profile:
        kwargs["credentials_profile_name"] = profile

    return kwargs


def _apply_proxy_signing(llm: Any) -> None:
    if bedrock_auth_mode() != "sigv4":
        return

    proxy_config = resolve_proxy_signing_config()
    if proxy_config is None:
        return

    client = getattr(llm, "client", None)
    if client is None:
        logger.warning("Bedrock LLM has no boto3 client; proxy signing hooks not installed")
        return

    install_proxy_sigv4_signing(client, proxy_config)
    logger.info(
        "Proxy sign-then-relay: signing_host=%s wire_host=%s routing_query=%r",
        proxy_config.signing_host,
        proxy_config.wire_host,
        proxy_config.routing_query or "(none)",
    )


def create_bedrock_llm(model_id: str | None = None):
    """LangChain Bedrock LLM — SigV4 signed for upstream Bedrock, routed via proxy when configured."""
    kwargs = _base_llm_kwargs(model_id)
    api = bedrock_api()
    proxy_config = resolve_proxy_signing_config()

    logger.info(
        "Bedrock api=%s auth=%s model=%s region=%s endpoint_url=%s signing_host=%s",
        api,
        bedrock_auth_mode(),
        kwargs["model_id"],
        kwargs["region_name"],
        kwargs.get("endpoint_url") or "(default AWS)",
        proxy_config.signing_host if proxy_config else "(n/a)",
    )

    if api == "converse":
        llm = ChatBedrockConverse(**kwargs)
    else:
        llm = ChatBedrock(**kwargs)

    _apply_proxy_signing(llm)
    return llm
