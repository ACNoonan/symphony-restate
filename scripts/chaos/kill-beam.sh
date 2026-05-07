#!/usr/bin/env bash
# Slice 5 chaos beat #2: kill the symphony-restate BEAM node.
#
# Expectation: BEAM dies → all Codex.Session GenServers + the
# CodexTurnService / RunAttemptWorkflow / IssueVO / SchedulerVO
# in-flight invocations on this node die with it. Restate's
# runtime detects the timeout and *retries* the in-flight
# invocations on whichever node is healthy.
#
# In a single-host demo, "another node" doesn't exist. The drama
# here is two-fold:
#
#   (a) The dashboard goes dark (because the dashboard is hosted
#       in the same BEAM that just died). Restart it with
#       `mix run --no-halt` and the durable state surfaces
#       unchanged.
#   (b) The Restate cluster keeps the workflow journal alive while
#       the BEAM is gone. When the BEAM comes back, Restate
#       redelivers the in-flight invocation, the workflow replay
#       returns journaled values for completed `ctx.run` blocks,
#       and the next `Codex.Session` is fresh — cold-path seeding
#       rebuilds codex context from the durable `conversation`.
#
# Watch on the dashboard, post-restart:
#   - `worker_node` updates to the new BEAM's node name
#   - `claim_status` is unchanged (Restate state survived)
#   - The conversation transcript is intact

set -euo pipefail

echo "=== chaos beat 2: kill the symphony-restate BEAM ==="
echo

# Match the mix run --no-halt process belonging to symphony-restate's
# umbrella root. `beam.smp` would also match other unrelated BEAM
# instances on the host; restrict to ones whose cwd / cmdline
# mentions symphony-restate.
TARGETS=$(pgrep -fl "beam.smp.*symphony-restate" || true)

if [ -z "${TARGETS}" ]; then
  # Fallback: match the mix command line specifically.
  TARGETS=$(pgrep -fl "mix(\s|/).*run.*no-halt" || true)
fi

if [ -z "${TARGETS}" ]; then
  echo "(no symphony-restate BEAM found — start it with 'mix run --no-halt')"
  exit 0
fi

echo "${TARGETS}"
echo
pkill -9 -f "beam.smp.*symphony-restate" || pkill -9 -f "mix(\s|/).*run.*no-halt" || true
echo
echo "=== killed. restart with 'mix run --no-halt'; expect Restate to redeliver in-flight invocations. ==="
