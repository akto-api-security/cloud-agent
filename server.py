"""Agent server with client-compatible Bedrock invoke endpoint."""

import logging
import os
import uuid
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import unquote

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from agent import AgentError, clear_session, create_agent, invoke_agent, stream_agent
from bedrock_config import (
    bedrock_api,
    bedrock_auth_mode,
    bedrock_stream_enabled,
    default_model_id,
    resolve_endpoint_url,
    resolve_proxy_signing_config,
    resolve_signing_host,
)

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)

agent = None
agents_by_model: dict[str, Any] = {}


def _get_agent(model_id: str | None = None):
    global agent
    if model_id is None or model_id == default_model_id():
        if agent is None:
            agent = create_agent()
        return agent

    if model_id not in agents_by_model:
        agents_by_model[model_id] = create_agent(model_id)
    return agents_by_model[model_id]


def _bedrock_host() -> str:
    region = os.getenv("AWS_REGION", "us-east-1")
    return f"bedrock-runtime.{region}.amazonaws.com"


@asynccontextmanager
async def lifespan(_: FastAPI):
    _get_agent()
    yield


app = FastAPI(title="Cloud Agent Server", lifespan=lifespan)


class ClientInvokeBody(BaseModel):
    """Client-style invoke payload."""

    message: str = Field(..., min_length=1)
    model: str | None = None
    requestId: str | None = None
    headers: dict[str, Any] | None = None


class ClientInvokeResponse(BaseModel):
    requestId: str
    model: str
    output: dict[str, str]
    headers: dict[str, str]


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=4000)
    thread_id: str | None = None


class ChatResponse(BaseModel):
    reply: str
    thread_id: str


@app.exception_handler(AgentError)
async def agent_error_handler(_: Request, exc: AgentError):
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.message},
    )


def _http_error_from_exception(exc: Exception) -> HTTPException:
    """Surface boto3/botocore errors (e.g. ChecksumMismatch) without masking."""
    logger.exception("Request failed: %s", exc)
    return HTTPException(
        status_code=502,
        detail=f"{type(exc).__name__}: {exc}",
    )


@app.get("/health")
def health():
    proxy = resolve_proxy_signing_config()
    return {
        "status": "ok",
        "bedrock_api": bedrock_api(),
        "bedrock_auth": bedrock_auth_mode(),
        "bedrock_stream": bedrock_stream_enabled(),
        "default_model": default_model_id(),
        "endpoint_url": resolve_endpoint_url(),
        "signing_host": resolve_signing_host(),
        "wire_host": proxy.wire_host if proxy else None,
    }


@app.post("/model/{model_id}/invoke", response_model=ClientInvokeResponse)
async def client_invoke(model_id: str, body: ClientInvokeBody, request: Request):
    """Client-compatible endpoint: POST /model/{model_id}/invoke"""
    model_id = unquote(model_id)
    request_id = body.requestId or str(uuid.uuid4())
    thread_id = request_id

    logger.info(
        "Client invoke model=%s requestId=%s inbound_headers=%s",
        model_id,
        request_id,
        dict(request.headers),
    )

    try:
        reply = invoke_agent(_get_agent(model_id), body.message, thread_id)
    except AgentError:
        raise
    except Exception as exc:
        raise _http_error_from_exception(exc) from exc

    return ClientInvokeResponse(
        requestId=request_id,
        model=body.model or model_id,
        output={"message": reply},
        headers=body.headers or {"host": _bedrock_host()},
    )


@app.post("/chat/stream")
def chat_stream(request: ChatRequest):
    """Stream tokens via Bedrock ConverseStream (requires BEDROCK_STREAM=true)."""
    if not bedrock_stream_enabled():
        raise HTTPException(
            status_code=400,
            detail="Streaming disabled. Set BEDROCK_STREAM=true.",
        )

    thread_id = request.thread_id or str(uuid.uuid4())

    def token_generator():
        for token in stream_agent(_get_agent(), request.message, thread_id):
            yield token

    return StreamingResponse(
        token_generator(),
        media_type="text/plain; charset=utf-8",
        headers={"X-Thread-Id": thread_id},
    )


@app.post("/chat", response_model=ChatResponse)
def chat(request: ChatRequest):
    thread_id = request.thread_id or str(uuid.uuid4())
    try:
        reply = invoke_agent(_get_agent(), request.message, thread_id)
    except AgentError:
        raise
    except Exception as exc:
        raise _http_error_from_exception(exc) from exc
    return ChatResponse(reply=reply, thread_id=thread_id)


@app.delete("/sessions/{thread_id}")
def delete_session(thread_id: str):
    clear_session(thread_id)
    return {"status": "deleted", "thread_id": thread_id}
