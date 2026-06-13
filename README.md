# cloud-agent

A **LangGraph ReAct agent** backed by **Amazon Bedrock Converse** via **boto3** (`langchain-aws` `ChatBedrockConverse`). Built to replicate a client-like LangChain + boto3 setup and test Akto proxy URL swaps.

## Stack

- **LangGraph** — ReAct agent loop (`create_react_agent`)
- **langchain-aws** — `ChatBedrockConverse` (boto3 `bedrock-runtime` client)
- **boto3 / botocore** — SigV4 via IAM profile; optional Bearer via `AWS_BEARER_TOKEN_BEDROCK`
- **FastAPI** — optional HTTP API

## Proxy (sign-then-relay)

```env
BEDROCK_ENDPOINT_URL=https://akto-proxy?openai_url=https://bedrock-runtime.<region>.amazonaws.com
```

Same as boto3 `endpoint_url`. The SDK:

1. Connects to the Akto proxy URL
2. **Signs** as if the request goes to `bedrock-runtime.<region>.amazonaws.com` (Host + canonical path/query)
3. Re-adds `openai_url` on the wire so Akto can route (unsigned; stripped before Bedrock)

Akto must **forward without mutating** signed fields (`Authorization`, `X-Amz-*`, path encoding). On forward, set `Host` to the upstream Bedrock host (`bedrock-runtime.<region>.amazonaws.com`); inbound wire may use the proxy `Host` for gateway routing.

```bash
./scripts/start-server.sh proxy
./scripts/run.sh proxy
```

Unset `BEDROCK_ENDPOINT_URL` for direct Bedrock.

## Prerequisites

- Python 3.10+
- IAM profile with Bedrock access (`AWS_PROFILE`, e.g. `cloud-agent-bedrock`)

## Setup (standard boto3 SigV4)

### Fresh account bootstrap

See **[docs/AWS-BOOTSTRAP.md](docs/AWS-BOOTSTRAP.md)** for full steps.

```bash
aws configure                    # admin keys for your AWS account
python3 -m venv .venv && source .venv/bin/activate
pip3 install -r requirements.txt
./scripts/bootstrap-account.sh   # creates IAM user/role/policy + tests Bedrock
```

### Existing credentials

```bash
./scripts/setup-aws.sh
```

The setup script walks through `aws configure`, optional assume-role profile, Bedrock smoke test, and writes `.env`.

### Setup script commands

| Command | What it does |
|---------|----------------|
| `./scripts/setup-aws.sh` | Full interactive setup |
| `./scripts/setup-aws.sh configure` | `aws configure` only |
| `./scripts/setup-aws.sh sso` | `aws configure sso` (IAM Identity Center) |
| `./scripts/setup-aws.sh role` | Add assume-role profile to `~/.aws/config` |
| `./scripts/setup-aws.sh verify` | `sts get-caller-identity` + Bedrock Converse test |
| `./scripts/setup-aws.sh test` | Run `debug_bedrock.py` (direct) |
| `./scripts/setup-aws.sh test-proxy` | Run `debug_bedrock.py` via Akto proxy |
| `./scripts/setup-aws.sh policy` | Print IAM policy reference |

### Admin: create IAM role (one-time)

If you have admin creds and need to create the Bedrock role:

```bash
./scripts/create-bedrock-role.sh
```

## Manual setup

```bash
cp .env.example .env
aws configure   # stores keys in ~/.aws/credentials
```

## Agent server

```http
POST /model/{model_id}/invoke
```

```bash
uvicorn server:app --port 8000
./scripts/test-client-invoke.sh "What is the weather in Mumbai?"
```

Simple curl body — SDK handles Bedrock auth headers:

```json
{"message": "What is the weather in Mumbai?"}
```

## Run

```bash
python3 agent.py              # CLI
python3 debug_bedrock.py      # wire header capture
uvicorn server:app --port 8000  # agent server (client + /chat APIs)
```

## Default model

`amazon.nova-micro-v1:0` (override with `BEDROCK_MODEL_ID` for your region / inference profile).

## Verified

| Mode | Result |
|------|--------|
| Direct `bedrock-runtime.<region>.amazonaws.com` | Works (SigV4) |
| Akto proxy sign-then-relay | SigV4 signed for upstream; requires Akto pass-through forward |

## Header encoding note

If headers look "encoded" in Akto dashboard but calls return 200, that's **ingestion JSON serialization** — not boto3 mutating headers on the wire. Use `debug_bedrock.py` to inspect actual outbound headers.
