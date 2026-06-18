"""Standard Bedrock ConverseStream via boto3.

botocore validates CRC32 on each AWS event-stream frame while iterating
``response["stream"]``. A proxy that rewrites or re-chunks the binary body
without updating frame checksums raises ``ChecksumMismatch``.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from typing import Any

from botocore.eventstream import ChecksumMismatch

logger = logging.getLogger(__name__)


def extract_text_delta(event: dict[str, Any]) -> str | None:
    if "contentBlockDelta" not in event:
        return None
    delta = event["contentBlockDelta"].get("delta") or {}
    return delta.get("text")


def iter_converse_stream_events(
    client: Any,
    *,
    model_id: str,
    messages: list[dict[str, Any]],
    system: list[dict[str, Any]] | None = None,
    tool_config: dict[str, Any] | None = None,
    inference_config: dict[str, Any] | None = None,
) -> Iterator[dict[str, Any]]:
    """Yield raw ConverseStream events. CRC32 validated by botocore on read."""
    kwargs: dict[str, Any] = {
        "modelId": model_id,
        "messages": messages,
    }
    if system:
        kwargs["system"] = system
    if tool_config:
        kwargs["toolConfig"] = tool_config
    if inference_config:
        kwargs["inferenceConfig"] = inference_config

    response = client.converse_stream(**kwargs)
    stream = response.get("stream")
    if stream is None:
        raise RuntimeError("converse_stream returned no stream")

    try:
        for event in stream:
            yield event
    finally:
        if hasattr(stream, "close"):
            stream.close()


def collect_converse_stream_text(
    client: Any,
    *,
    model_id: str,
    messages: list[dict[str, Any]],
    system: list[dict[str, Any]] | None = None,
    tool_config: dict[str, Any] | None = None,
    inference_config: dict[str, Any] | None = None,
) -> str:
    """Invoke via ConverseStream and return concatenated assistant text."""
    parts: list[str] = []
    for event in iter_converse_stream_events(
        client,
        model_id=model_id,
        messages=messages,
        system=system,
        tool_config=tool_config,
        inference_config=inference_config,
    ):
        if text := extract_text_delta(event):
            parts.append(text)
    return "".join(parts)


def is_checksum_mismatch(exc: BaseException) -> bool:
    return isinstance(exc, ChecksumMismatch)
