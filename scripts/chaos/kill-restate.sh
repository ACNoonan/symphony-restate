#!/usr/bin/env bash
# Slice 5 chaos beat #3: kill the Restate cluster node.
#
# Expectation: Restate goes away → the BEAM's outbound HTTP calls
# to Restate ingress (from the dashboard's RestateClient and from
# any in-flight `ctx.send_async` reschedules) start failing. The
# dashboard's "stale" badge surfaces immediately. In-flight
# invocations on the BEAM that were waiting for Restate signals
# stay parked.
#
# When Restate comes back (`docker compose up -d restate`):
#   - Restate replays its persisted journals from disk
#   - In-flight invocations resume where they left off
#   - The dashboard's stale badge clears
#   - Scheduled invocations (the SchedulerVO tick chain) fire on
#     their original `invoke_at_ms` if still in the future, or
#     immediately if past
#
# Watch on the dashboard:
#   - "stale (...)" badge appears in the header during the outage
#   - Clears once Restate is back; state matches pre-outage
#
# This is the most decisive Restate-as-source-of-truth beat —
# the BEAM stayed up the whole time, so any state the dashboard
# can show came from Restate's recovered journal.

set -euo pipefail

CONTAINER="${SYMPHONY_RESTATE_CONTAINER:-symphony-restate}"

echo "=== chaos beat 3: docker kill ${CONTAINER} ==="
echo

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "(no running container named '${CONTAINER}' — start it with './scripts/dev/up.sh')"
  exit 0
fi

docker kill "${CONTAINER}"
echo
echo "=== killed. dashboard should show 'stale'. restart with: ==="
echo "    docker compose up -d restate"
