#!/usr/bin/env bash
# Start agent server + simple curl test.
#
# Usage:
#   ./scripts/run.sh        # direct Bedrock
#   ./scripts/run.sh proxy  # only changes BEDROCK_ENDPOINT_URL

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -f .venv/bin/activate ]] || { echo "Run: python3 -m venv .venv && pip3 install -r requirements.txt"; exit 1; }
source .venv/bin/activate

export AWS_PROFILE="${AWS_PROFILE:-cloud-agent-bedrock}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"
export PORT=8000

unset AWS_BEARER_TOKEN_BEDROCK || true

if [[ "${1:-}" == "proxy" ]]; then
  export BEDROCK_ENDPOINT_URL="${BEDROCK_ENDPOINT_URL:-https://akto-proxy?openai_url=https://bedrock-runtime.${AWS_REGION}.amazonaws.com}"
  echo "Mode: proxy (BEDROCK_ENDPOINT_URL set)"
else
  unset BEDROCK_ENDPOINT_URL
  echo "Mode: direct Bedrock (default endpoint)"
fi

echo "Starting server on :${PORT}..."
uvicorn server:app --host 127.0.0.1 --port "$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 1
done

echo
curl -s "http://127.0.0.1:${PORT}/health" | python3 -m json.tool

echo
echo "Simple curl (SDK adds SigV4 auth headers on Bedrock call):"
AGENT_HOST="http://127.0.0.1:${PORT}" ./scripts/test-client-invoke.sh "What is the weather in Mumbai?"
