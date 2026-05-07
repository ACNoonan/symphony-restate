#!/usr/bin/env bash
# Register the host BEAM endpoint with the Restate cluster.
#
# Run this once after `mix run --no-halt` is up. The BEAM listens on
# :9082 by default; Restate's admin API is at :9070. From inside the
# Restate container the host BEAM is reachable via `host.docker.internal`
# on macOS / Docker Desktop or via `--net=host` on Linux.

set -euo pipefail

ENDPOINT="${SYMPHONY_BEAM_ENDPOINT:-http://host.docker.internal:9082}"
ADMIN="${SYMPHONY_RESTATE_ADMIN:-http://localhost:9070}"

echo "=== registering BEAM endpoint with Restate ==="
echo "    BEAM endpoint: ${ENDPOINT}"
echo "    Restate admin: ${ADMIN}"
echo

curl -fsSL -X POST "${ADMIN}/deployments" \
  -H "content-type: application/json" \
  -d "{\"uri\":\"${ENDPOINT}\",\"force\":true}" | jq . 2>/dev/null || true

echo
echo "=== registered services ==="
curl -fsSL "${ADMIN}/deployments" | jq '.deployments[] | {id, services: .services | map(.name)}' 2>/dev/null || \
  curl -fsSL "${ADMIN}/deployments"
