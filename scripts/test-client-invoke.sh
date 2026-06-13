#!/usr/bin/env bash
# Simple client curl — headers are added by boto3/SDK on outbound Bedrock calls.
#
# Usage:
#   ./scripts/test-client-invoke.sh
#   ./scripts/test-client-invoke.sh "What is the weather in Mumbai?"

set -euo pipefail

HOST="${AGENT_HOST:-http://localhost:8000}"
MODEL="${BEDROCK_MODEL_ID:-amazon.nova-micro-v1:0}"
MESSAGE="${1:-What is the weather in Mumbai?}"
ENCODED_MODEL="${MODEL//:/%3A}"

BODY="$(python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' "$MESSAGE")"

curl -sS -X POST "${HOST}/model/${ENCODED_MODEL}/invoke" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  | python3 -m json.tool
