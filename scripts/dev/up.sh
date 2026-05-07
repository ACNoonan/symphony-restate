#!/usr/bin/env bash
# Bring up the local Restate single-node container and wait for ingress.
# Used in the slice 5 demo flow:
#
#   ./scripts/dev/up.sh
#   mix run --no-halt              # in another shell
#   ./scripts/dev/register.sh      # after BEAM is up
#
# `down.sh` is the inverse.

set -euo pipefail

cd "$(dirname "$0")/../.."

echo "=== bringing up restate-server (single node) ==="
docker compose up -d restate

echo
echo "=== waiting for restate ingress (:8080) and admin (:9070) ==="
for i in {1..30}; do
  if curl -fsS http://localhost:9070/health >/dev/null 2>&1; then
    echo "restate is up"
    exit 0
  fi
  sleep 1
done

echo "restate did not become healthy in 30s; check 'docker compose logs restate'"
exit 1
