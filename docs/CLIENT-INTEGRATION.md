# Akto proxy — client configuration

Guide for teams running **LangChain / LangGraph** or **boto3** agents on **Amazon Bedrock** (SigV4). You do not deploy or operate the Akto proxy — Akto provides a URL; you point your Bedrock client at it.

---

## The URL

Akto gives you two values:


| From Akto                    | Example                                          |
| ---------------------------- | ------------------------------------------------ |
| **Proxy host**               | `https://akto-proxy`                             |
| **Your Bedrock runtime URL** | `https://bedrock-runtime.<region>.amazonaws.com` |


Set this on your agent (one env var):

```env
BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.<region>.amazonaws.com
```

Example:

```env
BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.ap-south-1.amazonaws.com
```

- `akto-proxy` — placeholder for the hostname Akto provides (no path)
- `<region>` — your Bedrock region; must match `AWS_REGION`
- `openai_url` — tells Akto which Bedrock runtime to forward to (required in the URL Akto gives you)

**Rollback:** unset `BEDROCK_ENDPOINT_URL` — your app calls Bedrock directly again.

---

## Configuration summary


| Setting                     | Direct Bedrock | Via Akto                       |
| --------------------------- | -------------- | ------------------------------ |
| `BEDROCK_ENDPOINT_URL`      | unset          | Akto URL above                 |
| `AWS_REGION`                | your region    | same region as in `openai_url` |
| `AWS_PROFILE` / IAM role    | unchanged      | unchanged                      |
| `BEDROCK_MODEL_ID`          | unchanged      | unchanged                      |
| Agent logic, tools, prompts | unchanged      | unchanged                      |


**Code change:** use `create_bedrock_llm()` instead of constructing `ChatBedrockConverse` directly (see below). Copy `[bedrock_config.py](../bedrock_config.py)` — it handles signing for the proxy.

---

## LangChain / LangGraph (recommended)

### 1. Copy `bedrock_config.py`

Copy `[bedrock_config.py](../bedrock_config.py)` into your project. No new dependencies.

### 2. Replace LLM construction

**Before:**

```python
from langchain_aws import ChatBedrockConverse

llm = ChatBedrockConverse(
    model_id="amazon.nova-micro-v1:0",
    region_name="ap-south-1",
    credentials_profile_name="my-profile",
)
```

**After:**

```python
from bedrock_config import create_bedrock_llm

llm = create_bedrock_llm()
```

Use `create_bedrock_llm()` everywhere you build the Bedrock LLM (including `create_react_agent(...)`).

### 3. Environment

```env
AWS_PROFILE=my-bedrock-profile
AWS_REGION=ap-south-1
BEDROCK_MODEL_ID=apac.amazon.nova-micro-v1:0

# Enable Akto — paste the URL Akto gave you:
BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.ap-south-1.amazonaws.com
```

That is the only difference vs direct Bedrock for most teams.

---

## Why a small hook module is required

Boto3 SigV4 signs **Host**, **path**, and **query**. With Akto in the middle you must:

1. Sign as if the request goes to `bedrock-runtime.<region>.amazonaws.com`
2. Send the signed request to the **Akto proxy host**
3. Keep `openai_url` on the wire for routing, but **exclude it from the signature**

`bedrock_config.py` does this via boto3 `before-sign` / `before-send` hooks. You do not implement signing yourself.

---

## Streaming (ConverseStream)

If your agent uses Bedrock streaming, add:

```env
BEDROCK_STREAM=true
```

`create_bedrock_llm()` then uses `converse_stream` (including when tools are bound). Same `BEDROCK_ENDPOINT_URL` — no separate streaming URL.

For **raw boto3** streaming (no LangChain), also copy `[bedrock_converse_stream.py](../bedrock_converse_stream.py)` and use `create_bedrock_runtime_client()`:

```python
from bedrock_config import create_bedrock_runtime_client, default_model_id
from bedrock_converse_stream import collect_converse_stream_text

client = create_bedrock_runtime_client()
reply = collect_converse_stream_text(
    client,
    model_id=default_model_id(),
    messages=[{"role": "user", "content": [{"text": "Hello"}]}],
    inference_config={"maxTokens": 256, "temperature": 0},
)
```

---

## Raw boto3 (no LangChain)

```python
import os
import boto3
from botocore.config import Config

from bedrock_config import (
    install_proxy_sigv4_signing,
    resolve_endpoint_url,
    resolve_proxy_signing_config,
)

client = boto3.client(
    "bedrock-runtime",
    region_name=os.environ["AWS_REGION"],
    endpoint_url=resolve_endpoint_url(),  # BEDROCK_ENDPOINT_URL
    config=Config(connect_timeout=90, read_timeout=90, retries={"max_attempts": 0}),
)

proxy_config = resolve_proxy_signing_config()
if proxy_config:
    install_proxy_sigv4_signing(client, proxy_config)

response = client.converse(
    modelId=os.environ["BEDROCK_MODEL_ID"],
    messages=[{"role": "user", "content": [{"text": "Hello"}]}],
)
```

Or use `create_bedrock_runtime_client()` from `bedrock_config.py` (same hooks, less boilerplate).

---

## Environment variables


| Variable               | Required          | Description                                                                                |
| ---------------------- | ----------------- | ------------------------------------------------------------------------------------------ |
| `BEDROCK_ENDPOINT_URL` | For Akto          | Full URL from Akto, including `?openai_url=https://bedrock-runtime.<region>.amazonaws.com` |
| `AWS_REGION`           | Yes               | Must match the region in `openai_url`                                                      |
| `AWS_PROFILE`          | If using profiles | IAM with `bedrock:Converse` / `bedrock:InvokeModel`                                        |
| `BEDROCK_MODEL_ID`     | Recommended       | Model or inference profile ID                                                              |
| `BEDROCK_STREAM`       | Optional          | `true` for ConverseStream                                                                  |
| `BEDROCK_SIGNING_HOST` | Rarely            | Only if Akto URL has no `openai_url` param                                                 |
| `BEDROCK_MAX_TOKENS`   | Optional          | Default `256`                                                                              |
| `LLM_TIMEOUT_SECONDS`  | Optional          | Default `90`                                                                               |


**Do not mix SigV4 and Bearer:** unset `AWS_BEARER_TOKEN_BEDROCK` when using IAM/`AWS_PROFILE`. `bedrock_config.py` clears Bearer automatically when a profile is set.

---

## Deploy your agent (not the proxy)

Set `BEDROCK_ENDPOINT_URL` in the environment where **your** agent runs.

**Local:**

```bash
export BEDROCK_ENDPOINT_URL="https://akto-proxy?openai_url=https://bedrock-runtime.us-east-1.amazonaws.com"
export AWS_REGION=us-east-1
python -m your_agent
```

**Kubernetes / Docker:**

```yaml
env:
  - name: BEDROCK_ENDPOINT_URL
    value: "https://akto-proxy?openai_url=https://bedrock-runtime.us-east-1.amazonaws.com"
  - name: AWS_REGION
    value: "us-east-1"
```

Use your existing IAM (IRSA, instance role, etc.). No proxy-side deployment on your side.

Toggle per environment: set the var in staging/prod, leave unset in dev for direct Bedrock if you prefer.

---

## Guardrail blocks

When Akto policy blocks a request (PII, prompt injection, etc.), the response looks like a **normal model reply** — the block reason appears as assistant text. Handle it like any other LLM output; no special error-code handling required if you use `create_bedrock_llm()`.

---

## Checklist

- [ ] `bedrock_config.py` in your repo; `create_bedrock_llm()` used for all Bedrock clients
- [ ] `BEDROCK_ENDPOINT_URL` set to the exact URL Akto provided
- [ ] `AWS_REGION` matches `openai_url`
- [ ] `AWS_BEARER_TOKEN_BEDROCK` unset when using IAM SigV4
- [ ] End-to-end agent test passes (including tools / multi-turn if you use them)
- [ ] If streaming: `BEDROCK_STREAM=true` and stream path tested

---

## Troubleshooting (client-side)


| Symptom                                          | What to check                                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `InvalidSignatureException`                      | `bedrock_config` hooks installed; URL includes `openai_url`; region matches                   |
| Requests still hit AWS directly                  | `BEDROCK_ENDPOINT_URL` not set in the running process, or client built without `endpoint_url` |
| `AccessDenied` from Bedrock                      | IAM role allows `bedrock:Converse` / `bedrock:ConverseStream` for your model                  |
| Bearer instead of SigV4                          | Unset `AWS_BEARER_TOKEN_BEDROCK`                                                              |
| Wrong region                                     | `AWS_REGION` must match host in `openai_url`                                                  |
| Stream not used                                  | Set `BEDROCK_STREAM=true`; use `create_bedrock_llm()` (forces streaming with tools)           |
| `ChecksumMismatch` or stream errors through Akto | Confirm `BEDROCK_ENDPOINT_URL` and hooks; if config is correct, contact Akto support          |


---

## Quick reference

```env
BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.<region>.amazonaws.com
AWS_REGION=<region>
BEDROCK_STREAM=true   # optional, for ConverseStream
```

```python
from bedrock_config import create_bedrock_llm
llm = create_bedrock_llm()
```

For IAM / Bedrock account setup in your AWS account, see [AWS-BOOTSTRAP.md](AWS-BOOTSTRAP.md).