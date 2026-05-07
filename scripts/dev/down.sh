#!/usr/bin/env bash
# Tear down the local Restate container.
#
# Note: this destroys Restate's persistent state in the container's
# volume. After `down.sh` then `up.sh`, all VO state, workflow
# journals, and scheduled invocations are gone — the demo is fresh.

set -euo pipefail

cd "$(dirname "$0")/../.."

echo "=== tearing down restate-server ==="
docker compose down --volumes
