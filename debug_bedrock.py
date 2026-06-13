"""
Log wire-level HTTP headers for Bedrock Converse calls (direct vs proxy).

Usage:
    python debug_bedrock.py

Set BEDROCK_ENDPOINT_URL to test the client-like proxy URL swap.
"""

import json
import logging
import os
import sys

from botocore.exceptions import ClientError
from dotenv import load_dotenv

from bedrock_config import create_bedrock_llm, default_model_id, resolve_endpoint_url

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(__name__)

CAPTURED_REQUESTS: list[dict] = []


def _truncate(value: str, limit: int = 120) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + "..."


def _register_before_send_hook(client) -> None:
    def before_send(request, **kwargs):
        url = request.url
        if isinstance(url, bytes):
            url = url.decode("utf-8")
        else:
            url = str(url)

        headers = {}
        for k, v in request.headers.items():
            key = k.decode("utf-8") if isinstance(k, bytes) else str(k)
            val = v.decode("utf-8") if isinstance(v, bytes) else str(v)
            headers[key] = val

        entry = {
            "method": request.method,
            "url": url,
            "headers": {
                k: _truncate(v) if k.lower() == "authorization" else v
                for k, v in sorted(headers.items())
            },
        }
        CAPTURED_REQUESTS.append(entry)
        print("\n--- Wire request (before-send) ---")
        print(f"  {entry['method']} {entry['url']}")
        for name, value in entry["headers"].items():
            print(f"  {name}: {value}")
        print("----------------------------------\n")

    client.meta.events.register("before-send", before_send)


def main() -> int:
    endpoint_url = resolve_endpoint_url()
    region = os.getenv("AWS_REGION", "us-east-1")
    model_id = os.getenv("BEDROCK_MODEL_ID", "").strip() or default_model_id()

    print("Bedrock wire-header debug")
    print(f"  region:       {region}")
    print(f"  model_id:     {model_id}")
    print(f"  endpoint_url: {endpoint_url or '(default AWS endpoint)'}")
    print()

    llm = create_bedrock_llm()
    client = llm.client
    _register_before_send_hook(client)

    prompt = "Reply with exactly: ok"
    print(f"Invoking Converse with prompt: {prompt!r}\n")

    try:
        response = llm.invoke(prompt)
        text = response.content if hasattr(response, "content") else str(response)
        print(f"SUCCESS — model reply: {text!r}\n")
        status = 0
    except ClientError as exc:
        error = exc.response.get("Error", {})
        print(f"FAILED — {error.get('Code')}: {error.get('Message')}\n")
        status = 1
    except Exception as exc:
        print(f"FAILED — {type(exc).__name__}: {exc}\n")
        status = 1

    if CAPTURED_REQUESTS:
        out_path = os.getenv("DEBUG_OUTPUT", "debug_bedrock_capture.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "endpoint_url": endpoint_url,
                    "region": region,
                    "model_id": model_id,
                    "requests": CAPTURED_REQUESTS,
                },
                f,
                indent=2,
            )
        print(f"Captured {len(CAPTURED_REQUESTS)} request(s) → {out_path}")

    return status


if __name__ == "__main__":
    sys.exit(main())
