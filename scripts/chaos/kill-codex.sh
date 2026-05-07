#!/usr/bin/env bash
# Slice 5 chaos beat #1: kill the codex Port child.
#
# Expectation: `Codex.Session.handle_info({port, {:exit_status, _}}, ...)`
# stops the GenServer cleanly. The DynamicSupervisor leaves it dead
# (transient restart). The currently in-flight `CodexTurnService.run`
# invocation returns `{:error, {:port_exit, _}}`, propagates a
# terminal failure, the workflow's `Awaitable.any` resolves on the
# turn handle with that failure, the attempt fails. On the next
# `mix symphony.dispatch` (or the next scheduler tick), `IssueVO`
# starts a new attempt — the cold-path seeding rebuilds codex
# context from the durable conversation in workflow state.
#
# Watch on the dashboard:
#   - `claim` flips from `running` → `failed`
#   - `last_attempt_n` increments on next dispatch
#   - The next attempt's conversation panel shows the prior
#     turns rebuilt on the fresh codex thread

set -euo pipefail

echo "=== chaos beat 1: pkill -9 codex ==="
echo "(target: codex Port child of the BEAM, not a remote node)"
echo

# Match codex processes precisely. The codex CLI is typically
# `codex app-server` for our use; match that command line so we
# don't accidentally hit a user-launched `codex` doing something else.
TARGETS=$(pgrep -fl "codex(\s|$|.*app-server)" || true)

if [ -z "${TARGETS}" ]; then
  echo "(no codex processes found — nothing to kill)"
  exit 0
fi

echo "${TARGETS}"
echo
pkill -9 -f "codex(\s|$|.*app-server)" || true
echo
echo "=== killed. expect Codex.Session GenServer to stop, attempt to fail. ==="
