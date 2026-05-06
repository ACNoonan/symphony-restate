# symphony-restate

OpenAI [Symphony](https://github.com/openai/symphony) on Restate — a durable substrate for the spec.

> **Status: pre-alpha, slice 4 done (2026-05-06).** Pivoted 2026-05-05. Built on
> [`restate-elixir`](https://github.com/ACNoonan/restate-elixir) v0.2.0 (local path-dep
> until Hex-published). Implements Symphony's `SPEC.md` external contract; internal
> architecture is Restate-native. See `docs/architecture.md`.

## What this is

Symphony's published `SPEC.md` openly states:

> Support tracker/filesystem-driven restart recovery without requiring a persistent
> database; exact in-memory scheduler state is not restored.

That's the gap Restate fills. `symphony-restate` is the same Symphony contract — same
`WORKFLOW.md`, same Linear adapter, same Codex app-server protocol — running on a
substrate where the orchestrator state *is* durable. Kill the host mid-flow; every
issue resumes on a different node, no double-dispatch, no lost claims.

## What this kills

The "in-memory orchestrator" caveat in `SPEC.md` §1. Drop in any OpenAI Symphony
`WORKFLOW.md`; `symphony-restate` runs it; the claim state and conversation journal
survive node death.

## Architecture (one paragraph)

External contract = `SPEC.md`. Internal architecture = Restate-native, with BEAM/OTP
and Restate as co-stars. Each Linear issue maps to a Restate **Virtual Object**
(`IssueVO`) that owns the *claim* (single-writer per issue ID). The actual `1..max_turns`
turn loop lives in a separate **Workflow** service (`RunAttemptWorkflow`), keyed by
`"\#{identifier}::a\#{attempt_n}"` — one workflow journal per attempt, holding the
pinned WORKFLOW.md content hash, the `conversation`, and per-turn comment ids.
`IssueVO.dispatch` synchronously calls into the workflow via `ctx.call`, so a
failover of either VO or workflow resumes from the journal it owns. The codex stdio
session itself is owned by an **OTP-supervised `Codex.Session` GenServer** pinned to
one BEAM node via Registry — fast turn-to-turn handoff while the node is healthy.
On node death, Restate retries the invocation on a different node; `Codex.Manager`
there spawns a fresh `Session`, whose cold-path seeding rebuilds codex's thread
context from the durable `conversation` state in one extra round-trip. Per-turn Linear
comments are idempotent via deterministic markers `(identifier, attempt_n, turn_n)` —
a replayed `ctx.run` after a lost response cannot duplicate them. The codex thread is
given a `linear_graphql` dynamic tool so the agent can read and write its own ticket.
Both substrates do what they're best at.

See `docs/architecture.md` for diagrams + the full mapping against `SPEC.md`.

## Restate primitives shown

Shipped through slice 3:

- **Virtual Object** state on `IssueVO` (per-issue `claim_status`, `last_attempt_n`,
  `last_attempt_result`; `worker_node` is persisted for observability only, never
  read for routing)
- **Workflow** state on `RunAttemptWorkflow` (per-attempt `workflow_content_hash`,
  `workspace_path`, durable `conversation`, `turn_count`, `last_comment_id`)
- **Virtual Object** state on `SchedulerVO` (per-project `running`, `interval_ms`,
  `last_tick_at_ms`, `dispatched_total`)
- `ctx.call` from `IssueVO` into `RunAttemptWorkflow` (durable cross-service call;
  retries journaled, terminal failures propagate)
- `ctx.call_async` + `Awaitable.any` for the codex-turn-vs-stall race in
  `RunAttemptWorkflow`
- `ctx.call_async` + `Awaitable.all` for the per-issue VO-state fan-out in
  `SchedulerVO.reconcile`
- `ctx.send_async(invoke_at_ms:)` for `SchedulerVO`'s self-rescheduling tick
  loop and for fire-and-forget per-issue dispatches
- `ctx.timer` for the stall timer
- `ctx.run` for journaled side effects (WORKFLOW.md load + content-hash pin,
  Linear fetch / idempotent comment, prompt render, system-time capture,
  port-kill on stall)
- `ctx.set_state` for the per-turn `conversation` append + per-tick scheduler
  bookkeeping

Planned in later slices:

- Chaos hooks + demo-script E2E (slice 5)

## Run it locally

```sh
# Prereqs: mix 1.19+, Erlang/OTP 28+, restate-server 1.6+, LINEAR_API_KEY in env,
# `codex` CLI on PATH (slice 1.5+ drives a real codex app-server stdio session).
mix deps.get
mix compile

# Run the pure-layer test suite (parser + Liquid render):
cd apps/symphony_core && mix test

# Boot the BEAM endpoint on :9082 (handlers register at start):
mix run --no-halt

# In another shell, register the deployment with restate-server:
restate --yes deployments register http://localhost:9082

# Edit WORKFLOW.md → set tracker.project_slug to your Linear project slug.

# Trigger one issue end-to-end (slice 1+):
mix symphony.dispatch SYM-1 --exec

# OR boot the per-project poll loop (slice 3+):
mix symphony.scheduler start your-project-slug --interval 30000 --exec

# Snapshot the per-issue VO states across the project at any time:
mix symphony.scheduler reconcile your-project-slug --exec

# Halt the loop:
mix symphony.scheduler stop your-project-slug --exec

# `mix run --no-halt` also boots the Phoenix LiveView dashboard (slice 4+)
# at http://localhost:4000 — auto-refreshes every 2s via SchedulerVO.reconcile,
# expand any issue row to see its current attempt's conversation.
```

`mix symphony.dispatch SYM-1` prints the curl, or pass `--exec` to run it. The
handler will: load WORKFLOW.md (`ctx.run`), fetch the issue from Linear (`ctx.run`),
ensure a workspace clone (`ctx.run`), then drive the `1..max_turns` loop — for each
turn it renders the prompt with Solid Liquid (`ctx.run`), drives a real codex turn
through the per-issue `Codex.Session` (`ctx.run`), appends `%{turn, prompt, response}`
to durable `conversation` state, posts a per-turn Linear comment (`ctx.run`), and
re-fetches the issue to break early on terminal tracker state. Kill the BEAM
mid-flow and Restate replays completed `ctx.run` blocks on resume; if the next turn
runs on a different node, the fresh `Codex.Session` rehydrates context from the
durable `conversation` via cold-path seeding.

## Demo script

`docs/demo-script.md` — TBD; lands with slice 5 (chaos beats).

## Status

| Slice | Scope | Status |
|---|---|---|
| 0 | Umbrella scaffold, Apache-2.0, deps wired | **done** |
| 1 | WORKFLOW.md parser + Liquid render in `:symphony_core`; `IssueVO.dispatch` w/ Linear fetch + post-comment + stub codex turn; `mix symphony.dispatch` task; endpoint registered on :9082 | **done (2026-05-05)** |
| 1.5 | Real `codex app-server` stdio session (single-shot port of upstream `SymphonyElixir.Codex.AppServer`); per-turn workspace ensure; auto-approval policy for non-interactive runs | **done (2026-05-05)** |
| 2 | `1..max_turns` continuation loop in `IssueVO`; per-issue `Codex.Session` GenServer pinned to one BEAM node via Registry + DynamicSupervisor; cold-path conversation seeding rebuilds codex thread on cross-node failover from durable `conversation` state; per-turn Linear comments + tracker re-fetch between turns | **done (2026-05-05)** |
| 2.5 | `IssueVO` slimmed to claim/dispatch; turn loop extracted into `RunAttemptWorkflow` (Workflow service, keyed `${id}::a${n}`); WORKFLOW.md content-hash pinned per attempt; node-local workspace preflight outside `ctx.run`; idempotent Linear comments via `(identifier, attempt_n, turn_n)` markers; idle-timeout for `Codex.Session`; `linear_graphql` dynamic tool so the agent can drive its own ticket | **done (2026-05-05)** |
| 3 | Codex turn extracted as `CodexTurnService` (Restate Service); workflow uses `ctx.call_async` + `ctx.timer` + `Awaitable.any` for the turn-vs-stall race; on stall, kills `Codex.Session` port and raises terminal failure; `IssueVO.read_state` shared handler for snapshots; `Linear.list_issues_in_project!`; `SchedulerVO` poll loop self-rescheduling via `ctx.send_async(invoke_at_ms:)` + `Awaitable.all` reconciliation across N issues; `mix symphony.scheduler {start,stop,tick,reconcile}` driver | **done (2026-05-06)** |
| 4 | New `:symphony_dashboard` umbrella app: Phoenix 1.7 + LiveView 1.0 on `:4000`, single `OverviewLive` with 2s auto-refresh; `RestateClient` HTTP wrapper hitting Restate ingress for `SchedulerVO.reconcile` + `IssueVO.readState` + `RunAttemptWorkflow.readState`; click-to-expand attempt panels showing conversation, content-hash pin, workspace_path; stale-state badge surfaces ingress failure; no asset pipeline (Phoenix/LV JS served from each dep's priv/static) | **done (2026-05-06)** |
| 5 | Chaos beats (`pkill` codex / BEAM node / Restate node) | not started |

Demo readiness gate: see [`demo-engineering.md` §6](../demo-engineering.md).

## License

Apache-2.0 (matching upstream Symphony). Portions of this code are derived from
[OpenAI Symphony](https://github.com/openai/symphony); see [`NOTICE`](NOTICE) for
the per-module attribution.
