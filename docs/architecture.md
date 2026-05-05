# symphony-restate — Architecture

External contract: OpenAI Symphony [`SPEC.md`](https://github.com/openai/symphony/blob/main/SPEC.md).
Internal substrate: Restate (durable execution) + BEAM/OTP (process supervision), as
co-stars.

## SPEC.md mapping

| `SPEC.md` concept | Implementation here |
|---|---|
| §3.1.4 Orchestrator (in-memory state) | **Removed as a component.** Each issue is its own Virtual Object. No central authority. |
| §4.1.8 Orchestrator Runtime State | Distributed across VO state + Workflow journals. Never serialized as one object. |
| §7.1 Issue States (`Unclaimed`/`Claimed`/`Running`/`RetryQueued`) | VO state machine. Single-writer guarantee makes "claimed" trivially correct. |
| §7.2 Run Attempt (11 phases) | Workflow invocation. Each phase = a journal entry. Phases fall out of impl, not enumerated. |
| §8.1 Poll Loop | Scheduled VO self-invocation via `ctx.send` w/ `delayMillis`. Suspends to ~$0 between ticks. |
| §8.4 Retry/Backoff | `ctx.run` retry policy + `ctx.sleep`. Cancellable as a sub-invocation. |
| §8.5 Stall Detection | `Awaitable.any([turn_complete, ctx.sleep(stall_ms)])` — wins or stalls, no math. |
| §6.2 Dynamic `WORKFLOW.md` reload | **Replaced.** Workflow definition is a deployment artifact. Redeploy → new invocations use new config; in-flight finish on old. |
| §5 `WORKFLOW.md` format | **Kept as-is.** External contract. |
| §5.4 Liquid template rendering | Pure function in `:symphony_core`. Called from inside `ctx.run`. |
| Linear adapter | Same external behavior. Each call wrapped in `ctx.run` for journaling. |
| Codex stdio app-server | OTP-supervised port; per-turn input + output journaled via `ctx.run`. Process not durable; conversation is. |
| Phoenix LiveView dashboard | Reads Restate admin API + journal queries instead of GenServer state. |

## Co-star design

The thesis behind `restate-elixir` is that BEAM is the best-fit substrate for
Restate's journal-replay semantics. This demo has to make that case visually — both
runtimes need to be on screen, not one hidden behind the other.

### What OTP does

- `Codex.Session` GenServers — one per pinned issue, owns the stdio port.
- `Codex.Supervisor` — `:one_for_one`, restarts a dead session on the same node.
- Linear client GenServer pool, port draining on shutdown, telemetry pipelines.
- Phoenix LiveView dashboard process tree.

### What Restate does

- `IssueVO` — durable claim state, `worker_node`, `turn_count`,
  `conversation_journal_ref`. Single-writer per issue ID.
- `RunAttemptWorkflow` — durable per-attempt: prepare workspace, render prompt,
  send turn, await response, post comment, record outcome. Survives any handler
  crash mid-flow.
- Scheduler VO — durable poll-tick loop with `ctx.sleep`.
- Cancellation propagation — terminal-state issue cancels live run as a
  sub-invocation.

### Where they meet

```
┌─────────────────────────── BEAM Node A ──────────────────────────┐
│                                                                  │
│   ┌─────────────────────┐    ┌──────────────────────────────┐    │
│   │ Codex.Supervisor    │    │ Restate Handler Endpoint     │    │
│   │  └ Codex.Session    │◀───│  IssueVO.run_turn/2          │    │
│   │     (port: codex    │    │  RunAttemptWorkflow.send/2   │    │
│   │      app-server)    │    │                              │    │
│   └─────────────────────┘    └──────────────────────────────┘    │
│           ▲                              │                       │
│           │ stdio turn I/O               │ ctx.run journals      │
│           │ (fast, in-process)           │ each turn input/output│
│           │                              ▼                       │
└───────────┼──────────────────────────────────────────────────────┘
            │
            │ (worker_node = A in VO state)
            │
            ▼
   ┌──────────────────────────┐
   │  Restate Cluster          │
   │  - IssueVO state (KV)     │
   │  - Workflow journals      │
   │  - Scheduled invocations  │
   └──────────────────────────┘
```

### Failure beats

1. **Codex port dies (`pkill -9 codex`).** OTP supervisor restarts `Codex.Session`
   on Node A. The next `IssueVO.run_turn` sees a fresh port; replays the
   conversation from journal; continues. Pure OTP recovery.
2. **BEAM Node A dies.** `Codex.Session` dies with it. Next `IssueVO.run_turn`
   invocation is routed to Node B (Restate cluster decision). Node B has no
   `Codex.Session` for this issue; it spawns one, replays the conversation from
   the Workflow journal, continues. Co-star handoff.
3. **Restate node dies mid-handler-call.** Restate cluster re-routes the
   invocation; VO state untouched; the call retries durably. The OTP side never
   notices because the durable state didn't move.

## Slice-by-slice architecture growth

| Slice | New components | New design risk |
|---|---|---|
| 0 | Umbrella, deps, types | None. |
| 1 | `Symphony.Core.Workflow` parser; `IssueVO` (single-method, `dispatch/0`); single-turn `RunAttemptWorkflow`; `Codex.Session` (one-shot turn); minimal Linear adapter. | Restate-Elixir handler discovery + endpoint registration — first time we run a non-greeter handler. |
| 2 | `max_turns` loop in `RunAttemptWorkflow`; pinned-session lifecycle in `Codex.Session`; conversation replay on respawn. | Worker-node affinity routing. May need a `restate-elixir` SDK addition. |
| 3 | `Scheduler` VO (poll-tick); reconciliation across N issues (`Awaitable.all`); stall detection (`Awaitable.any`). | First fan-out concurrency in real Symphony workload. |
| 4 | Phoenix LiveView dashboard; reads Restate admin API + journals. | Live updates from Restate-side state changes (likely PubSub-bridged). |
| 5 | Chaos hooks (kill codex / kill BEAM node / kill Restate node); demo-script E2E. | None new — exercise of slices 1–4 under chaos. |

## Open architectural items

- **Worker-node affinity.** `IssueVO` knows `worker_node`; how does the Restate
  handler endpoint route the next call to that node? Likely `ctx.run` returning the
  current node-id and a `restate-elixir` helper for "send to specific endpoint" — TBD
  in slice 2.
- **Rendezvous on dead pin.** When `worker_node` is unreachable, what's the exact
  recovery sequence? Needs a small design doc before slice 2.
- **HTTP/2 same-stream suspend/resume.** Long codex turns will exercise the
  REQUEST_RESPONSE-only path in `restate-elixir` v0.2.0. May force the v0.3 work.
