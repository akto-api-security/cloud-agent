#!/usr/bin/env bash
# Start the agent server (foreground).
#
# Usage:
#   ./scripts/start-server.sh              # direct Bedrock
#   ./scripts/start-server.sh proxy        # via Akto proxy (from .env or default)
#   ./scripts/start-server.sh proxy stream # proxy + ConverseStream (BEDROCK_STREAM=true)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -f .venv/bin/activate ]] || { echo "Run: python3 -m venv .venv && pip3 install -r requirements.txt"; exit 1; }
source .venv/bin/activate

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

export AWS_PROFILE="${AWS_PROFILE:-cloud-agent-bedrock}"
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-apac.amazon.nova-micro-v1:0}"
export PORT="${PORT:-8000}"

unset AWS_BEARER_TOKEN_BEDROCK || true

MODE="${1:-}"
STREAM_ARG="${2:-}"

if [[ "$MODE" == "proxy" ]]; then
  if [[ -z "${BEDROCK_ENDPOINT_URL:-}" ]]; then
    export BEDROCK_ENDPOINT_URL="https://akto-proxy?openai_url=https://bedrock-runtime.${AWS_REGION}.amazonaws.com"
  fi
  echo "proxy → $BEDROCK_ENDPOINT_URL"
  echo "signing_host → bedrock-runtime.${AWS_REGION}.amazonaws.com (from openai_url)"
else
  unset BEDROCK_ENDPOINT_URL
  echo "direct Bedrock → bedrock-runtime.${AWS_REGION}.amazonaws.com"
fi

if [[ "$STREAM_ARG" == "stream" ]] || [[ "${BEDROCK_STREAM:-}" == "true" ]]; then
  export BEDROCK_STREAM=true
  echo "stream → BEDROCK_STREAM=true (ConverseStream)"
fi

ENCODED_MODEL="${BEDROCK_MODEL_ID//:/%3A}"
BASE="http://127.0.0.1:${PORT}"

echo
echo "health   → ${BASE}/health"
echo "invoke   → POST ${BASE}/model/${ENCODED_MODEL}/invoke"
echo "chat     → POST ${BASE}/chat"
if [[ "${BEDROCK_STREAM:-}" == "true" ]]; then
  echo "stream   → POST ${BASE}/chat/stream"
fi
echo
echo "curl tests (in another terminal):"
echo "  ./scripts/test-curl.sh"
if [[ "${BEDROCK_STREAM:-}" == "true" ]]; then
  echo "  ./scripts/test-curl.sh stream"
fi
echo

exec uvicorn server:app --host 127.0.0.1 --port "$PORT"
