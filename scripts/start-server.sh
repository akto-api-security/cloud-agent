#!/usr/bin/env bash
# Start the agent server (foreground).
#
# Usage:
#   ./scripts/start-server.sh         # direct Bedrock
#   ./scripts/start-server.sh proxy   # via Akto proxy (BEDROCK_ENDPOINT_URL only)

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
export AWS_REGION="${AWS_REGION:-us-east-1}"
export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"
export PORT="${PORT:-8000}"

unset AWS_BEARER_TOKEN_BEDROCK || true

if [[ "${1:-}" == "proxy" ]]; then
  export BEDROCK_ENDPOINT_URL="${BEDROCK_ENDPOINT_URL:-https://akto-proxy?openai_url=https://bedrock-runtime.${AWS_REGION}.amazonaws.com}"
  echo "proxy → $BEDROCK_ENDPOINT_URL"
  echo "signing_host → bedrock-runtime.${AWS_REGION}.amazonaws.com (from openai_url)"
else
  unset BEDROCK_ENDPOINT_URL
  echo "direct Bedrock → bedrock-runtime.${AWS_REGION}.amazonaws.com"
fi

echo "http://127.0.0.1:${PORT}/health"
echo "POST http://127.0.0.1:${PORT}/model/${BEDROCK_MODEL_ID//:/%3A}/invoke"
echo

exec uvicorn server:app --host 127.0.0.1 --port "$PORT"
