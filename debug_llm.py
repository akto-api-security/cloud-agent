"""
Smoke-test Mantle LLM calls (direct or via Akto ?openai_url= proxy).

Usage:
    python debug_llm.py
"""

import json
import logging
import os
import sys

import httpx
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)


def _api_key() -> str:
    for env_var in ("OPENAI_API_KEY", "AWS_BEARER_TOKEN_BEDROCK"):
        value = os.getenv(env_var, "").strip()
        if value:
            return value
    raise RuntimeError("Set OPENAI_API_KEY or AWS_BEARER_TOKEN_BEDROCK")


def _truncate(value: str, limit: int = 80) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + "..."


def main() -> int:
    base_url = os.getenv("OPENAI_BASE_URL", "").strip().rstrip("/")
    model = os.getenv("OPENAI_MODEL", "mistral.ministral-3-3b-instruct")
    api_key = _api_key()

    if not base_url:
        print("ERROR: OPENAI_BASE_URL is required")
        return 1

    url = f"{base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {_truncate(api_key, 40)}...",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
        "max_tokens": 16,
        "temperature": 0,
    }

    print("Mantle LLM smoke test")
    print(f"  url:   {url}")
    print(f"  model: {model}")
    print()

    real_headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    response = None
    try:
        with httpx.Client(timeout=90.0) as client:
            response = client.post(url, headers=real_headers, json=payload)
        print(f"Status: {response.status_code}")
        print(f"Response headers: {dict(response.headers)}")
        data = response.json()
        if response.is_success:
            reply = data["choices"][0]["message"]["content"]
            print(f"SUCCESS — reply: {reply!r}")
            status = 0
        else:
            print(f"FAILED — body: {json.dumps(data, indent=2)}")
            status = 1
    except Exception as exc:
        print(f"FAILED — {type(exc).__name__}: {exc}")
        status = 1

    capture = {
        "request": {
            "url": url,
            "headers": headers,
            "body": payload,
        },
        "status": response.status_code if response is not None else None,
    }
    out_path = os.getenv("DEBUG_OUTPUT", "debug_llm_capture.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(capture, f, indent=2)
    print(f"\nSaved capture → {out_path}")

    return status


if __name__ == "__main__":
    sys.exit(main())
