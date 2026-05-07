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
| §7.2 Run Attempt (11 phases) | `RunAttemptWorkflow` invocation. Each durable boundary = a journal entry. The 11 phases fall out of implementation, not enum bookkeeping. |
| §8.1 Poll Loop | `SchedulerVO` (per-project key) self-schedules its `tick` handler via `ctx.send_async(self, "tick", nil, invoke_at_ms: now + interval_ms)`. Suspends to ~$0 between ticks. |
| §8.4 Retry/Backoff | Workflow-level retry policy + durable timers. Cancellable because the run attempt is its own invocation, not a hidden local loop. |
| §8.5 Stall Detection | `Awaitable.any([turn_handle, ctx.timer(stall_timeout_ms)])` in `RunAttemptWorkflow`, where `turn_handle` is a `Context.call_async` to `CodexTurnService`. On stall, the `Codex.Session` port is killed so the abandoned turn releases resources. |
| §6.2 Dynamic `WORKFLOW.md` reload | **Replaced.** Workflow definition is a deployment artifact. Each attempt pins `workflow_version` / content hash; redeploy affects new attempts only. |
| §5 `WORKFLOW.md` format | **Kept as-is.** External contract. |
| §5.4 Liquid template rendering | Pure function in `:symphony_core`. Called from inside `ctx.run`. |
| Linear adapter | Same external behavior. Reads are journaled. Writes use deterministic markers / idempotency checks so retry cannot duplicate comments. |
| Codex stdio app-server | OTP-supervised port. The process is not durable; turn requests, completions, transcript refs, and cancellation state are. |
| Phoenix LiveView dashboard | `Symphony.Dashboard.OverviewLive` reads our own observability handlers (`SchedulerVO.reconcile`, `IssueVO.readState`, `RunAttemptWorkflow.readState`) over Restate ingress — same path any other Restate client would use. No GenServer state, no journal reads (yet). |

## Co-star design

The thesis behind `restate-elixir` is that BEAM is the best-fit substrate for
Restate's journal-replay semantics. This demo has to make that case visually — both
runtimes need to be on screen, not one hidden behind the other.

### What OTP does

- `Codex.Session` GenServers — one per pinned issue, owns the stdio port.
- `Codex.Supervisor` — `:one_for_one`, restarts a dead session on the same node.
- Port draining on shutdown, telemetry pipelines, and optional backpressure /
  rate-limit processes. HTTP connection pooling stays in Req/Finch unless we need
  an actual stateful coordinator.
- Phoenix LiveView dashboard process tree.

### What Restate does

- `IssueVO` — durable claim state, `worker_node`, `turn_count`,
  current attempt id, `conversation_journal_ref`. Single-writer per issue ID.
- `RunAttemptWorkflow` — durable per-attempt: prepare workspace, render prompt,
  request a Codex turn, await response, post comment idempotently, record
  outcome. Survives any handler crash mid-flow.
- Scheduler VO — durable poll-tick loop with `ctx.sleep`.
- Cancellation propagation — terminal-state issue cancels live run as a
  sub-invocation.

### Where they meet

```
┌─────────────────────────── BEAM Node A ──────────────────────────┐
│                                                                  │
│   ┌─────────────────────┐    ┌──────────────────────────────┐    │
│   │ Codex.Supervisor    │    │ Restate Handler Endpoint     │    │
│   │  └ Codex.Session    │◀───│  IssueVO.dispatch/2          │    │
│   │     (port: codex    │    │  RunAttemptWorkflow.run/2    │    │
│   │      app-server)    │    │                              │    │
│   └─────────────────────┘    └──────────────────────────────┘    │
│           ▲                              │                       │
│           │ stdio turn I/O               │ journaled turn reqs   │
│           │ (fast, in-process)           │ completions + refs    │
│           │                              ▼                       │
└───────────┼──────────────────────────────────────────────────────┘
            │
            │ (worker_node = A for observability only)
            │
            ▼
   ┌──────────────────────────┐
   │  Restate Cluster          │
   │  - IssueVO state (KV)     │
   │  - Workflow journals      │
   │  - Scheduled invocations  │
   └──────────────────────────┘
```

## Durable/live boundary

The boundary rule: Restate owns decisions that must survive time; OTP owns
processes that make the current node useful.

That means a live Codex port is never treated as durable state. It is a cache of
agent context with a process attached. The durable record is the turn request,
the completion or failure, the transcript reference, the workflow version, and
enough workspace metadata to restart on another node. If a BEAM node dies, the
new node may lose the warm thread, but it must not lose the right to continue
the attempt or duplicate externally visible writes.

Slice 2 deliberately cheated this boundary for speed: `IssueVO` called
`Codex.Manager.run_turn/6` inside `ctx.run` — a blocking local call with no
awaitable handle. **Slice 3 closes the cheat**: the codex turn is its own
Restate Service (`CodexTurnService`); `RunAttemptWorkflow` issues it via
`ctx.call_async` and races the resulting handle against `ctx.timer(stall_timeout_ms)`
through `Awaitable.any/2`. On stall, the workflow kills the local
`Codex.Session` port (so the abandoned in-flight turn releases its file
descriptors) and raises a terminal `codex_turn_stall` failure for the attempt.
Cancellation across the call tree is best-effort — Restate's CANCEL signal raises
at the *next suspending op*, so a turn already inside `ctx.run` runs to its
own completion before the cancel surfaces; the port-kill is the OTP-side
preemption that meets the cancel halfway.

### Failure beats (slice 3 implementation status)

1. **Codex port dies (`pkill -9 codex`).** `Codex.Session.handle_info/2` catches
   `{port, {:exit_status, _}}` and stops the GenServer. The DynamicSupervisor
   does *not* auto-restart (transient). On the next `Manager.run_turn/6` the
   Manager sees no Registry entry, spawns a fresh Session, and the cold-path
   seeding (preamble built from durable `conversation` state) rehydrates codex.
   Implemented in slice 2.
2. **BEAM Node A dies.** `Codex.Session` and the in-flight `CodexTurnService`
   invocation on Node A die with the BEAM. Restate's runtime detects the
   timeout and retries the invocation; routing picks Node B. `RunAttemptWorkflow`
   is unaffected (its `call_async` handle is durable; the result still arrives
   when the retry on Node B completes). On Node B `Manager.run_turn/6` has no
   Session for this issue, spawns one, cold-path preamble rebuilds context.
   Implemented in slices 2 + 3.
3. **Restate cluster node dies mid-handler-call.** Restate cluster re-routes
   the invocation; VO/Workflow state untouched; the call retries durably. The
   OTP side never notices because the durable state didn't move. Implemented
   at the Restate-Elixir SDK layer; symphony-restate inherits it for free.
4. **Codex turn stalls (no progress for `codex.stall_timeout_ms`).** Slice 3
   `RunAttemptWorkflow.run_turn_with_stall_detection/8` races the
   `CodexTurnService` invocation against a `ctx.timer`. Stall wins → kill the
   local `Codex.Session` port (the in-flight `Manager.run_turn` returns a
   port-exit error, the `CodexTurnService` invocation completes with terminal
   failure, and its result is abandoned because the workflow already took the
   stall branch); raise `Restate.TerminalError{message: "codex_turn_stall: ..."}`
   for the attempt; `IssueVO` records `claim_status="failed"` and surfaces the
   error to whoever invoked it (operator, scheduler).
5. **Issue goes to a tracker terminal state mid-attempt.** Existing slice 2
   behavior preserved: `RunAttemptWorkflow` re-fetches the issue between turns
   and breaks the loop early if `state` is in `terminal_states`. Slice 3 does
   not yet preempt mid-turn; that requires `Context.cancel_invocation` on the
   live `CodexTurnService` invocation id, which `call_async` does not directly
   expose — flagged for slice 4/5 if the demo needs it.

## Slice-by-slice architecture growth

| Slice | New components | Status |
|---|---|---|
| 0 | Umbrella, deps, types | done |
| 1 | `Symphony.Core.Workflow` parser; `Symphony.Core.Prompt` (Solid Liquid render); `IssueVO.dispatch` (single turn, stub codex); `Symphony.Runtime.Linear` (fetch/post-comment); `mix symphony.dispatch` task. | done |
| 1.5 | `Symphony.Runtime.Codex.AppServer` — minimal port of upstream's stdio JSON-RPC client (single-shot `run/4`); auto-approval policy; `Codex.Workspace.ensure!/2`. | done |
| 2 | `Codex.AppServer.start/2` + `turn/4` + `stop/1` (broken out so port stays warm); `Codex.Session` GenServer (long-lived port + thread, cold-path seeding); `Codex.Supervisor` DynamicSupervisor + `Codex.Registry`; `Codex.Manager` find-or-spawn API; `IssueVO` `1..max_turns` loop with durable `conversation` state; per-turn Linear comment; mid-loop tracker re-fetch + terminal-state break; `Codex.Manager.stop_session/1` on terminal. | done |
| 2.5 | `IssueVO` slimmed to claim/dispatch (`claim_status`, `last_attempt_n`, `worker_node`); turn loop extracted into `RunAttemptWorkflow` (Workflow service keyed `${id}::a${n}`); WORKFLOW.md content read inside `ctx.run` so its bytes (and the SHA-256 hash) are pinned per attempt; `Workspace` split into `path_for/2` (journaled, inside `ctx.run`) + `preflight_local!/1` (outside, every replay) so cross-node resumes don't see a missing cwd; `Linear.post_comment_idempotent!/3` w/ deterministic `(identifier, attempt_n, turn_n)` marker; `Codex.Session` idle timeout w/ `Manager.run_turn` retry-on-noproc; `Codex.DynamicTool` registers `linear_graphql` on `thread/start` and dispatches `item/tool/call`. | done |
| 3 | `CodexTurnService` extracts the codex turn into a Restate Service so the workflow gets an awaitable handle; `RunAttemptWorkflow` races the turn against `ctx.timer(stall_timeout_ms)` via `Awaitable.any`, kills `Codex.Session` on stall, raises terminal `codex_turn_stall`; `IssueVO.read_state` shared handler for non-mutating snapshots; `Linear.list_issues_in_project!` + active-state filter; `SchedulerVO` per-project poll loop self-rescheduling its `tick` via `ctx.send_async(invoke_at_ms:)`, fanning out per-issue dispatches via `send_async`, and `reconcile` reading N issues' VO state in parallel with `call_async` + `Awaitable.all`; `mix symphony.scheduler {start,stop,tick,reconcile}` CLI. | done |
| 4 | New `:symphony_dashboard` umbrella app: Phoenix 1.7 + LiveView 1.0 on `:4000`; `Symphony.Dashboard.OverviewLive` with 2s auto-refresh via `Process.send_after(:refresh)`; `Symphony.Dashboard.RestateClient` (Req-based HTTP wrapper for ingress) reads `SchedulerVO.reconcile` / `IssueVO.readState` / `RunAttemptWorkflow.readState`; click-to-expand row panels show per-attempt conversation, content-hash pin, workspace_path; `RunAttemptWorkflow.read_state` shared handler added; layout serves Phoenix + LV JS from each dep's `priv/static` (no asset pipeline). | done |
| 5 | Root `docker-compose.yml` running single-node Restate 1.6.2 (BEAM stays on host so the codex Port child is `pkill`-able); `scripts/dev/{up,down,register}.sh` boot helpers; three chaos beats in `scripts/chaos/`: `kill-codex.sh` (port child), `kill-beam.sh` (host BEAM), `kill-restate.sh` (`docker kill` the cluster node); `mix symphony.chaos {kill_codex,kill_beam,kill_restate}` wrapper; `docs/demo-script.md` narrative — each beat zeroed in on a specific architectural invariant from the table above. | done |

## Resolved architectural items (slice 2)

- ~~**Worker-node affinity.**~~ Resolved by *not* tracking it explicitly.
  `IssueVO` runs wherever Restate routes it; `Codex.Manager` finds-or-spawns a
  Session local to that node via Registry. The "affinity" is implicit in
  Restate's routing decisions; no SDK addition needed for slice 2. We do
  persist `worker_node` to VO state for observability, but it's never read for
  routing.
- ~~**Rendezvous on dead pin.**~~ Replaced with the cold-path seeding pattern in
  `Codex.Session`: when a fresh Session sees `expected_completed_turns >
  completed_turns`, it prepends a "Prior conversation" preamble to the next
  prompt, catching codex up in one extra round-trip. No separate seed turn,
  no wasted assistant reply. Trade-off: prompt size grows linearly with turn
  count, mitigated by codex's prompt caching.

## Architectural invariants

- **No central orchestrator process.** Scheduling is centralized as a
  durable VO tick (`SchedulerVO`, one per project slug), but issue
  correctness always lives at the per-issue key.
- **No durable illusion around ports.** A `Codex.Session` may die at any time.
  Durable state must be sufficient to restart on a different BEAM node.
- **No blocking local call where the design promises a durable race.** Stall
  detection, cancellation, and long-turn recovery need Restate awaitables or
  sub-invocations, not a GenServer call hidden inside `ctx.run`.
- **No unkeyed external writes.** Linear comments, branch pushes, and any future
  tracker/file-system writes need deterministic markers or idempotency keys.
- **No node-local path in the journal unless storage is shared.** If a workspace
  path is replayed on another node, either the path must point at shared storage
  or the new node must run an idempotent local preflight before Codex uses it.

## Still open

- **HTTP/2 same-stream suspend/resume.** Long codex turns (hour-scale) will
  exercise the REQUEST_RESPONSE-only path in `restate-elixir` v0.2.0. Slice 2
  builds run successfully but real long-turn smoke testing may force the v0.3
  work — flagged for the SDK side.
- **Conversation state size.** Restate Workflow state has size limits; long-running
  attempts (20 turns × N kB each) may hit them. Slice 2.5 keeps the conversation
  in workflow state; slice 3 may move it to per-turn blobs / durable promises,
  summarize older turns, or store compressed refs instead of full text.
- **JSON-encodability of `ctx.run` results.** `restate-elixir` JSON-encodes the
  result of every `ctx.run` block on first execution and JSON-decodes it on
  replay. Tuples and structs without `Jason.Encoder` blow up at the propose step.
  `RunAttemptWorkflow` returns plain string-keyed maps throughout; the legacy
  `IssueVO` slice 2 code that returned `{config, tmpl}` tuples / `Issue` structs
  from `ctx.run` was a latent bug — slice 2.5 routed around it by extracting
  the loop into the workflow. Worth a follow-up audit on any remaining
  `Linear.fetch_issue!`-inside-`ctx.run` calls.

## Resolved in slice 2.5

- ~~**`Codex.Session` idle timeout.**~~ Configurable via
  `:codex_session_idle_timeout_ms` (default 5 min). Idle Sessions stop
  cleanly; `Manager.run_turn` retries once on `:noproc` / `:normal` to
  cover the race against an in-flight call. Cold-path seeding rebuilds
  context from the workflow's durable `conversation`.
- ~~**Idempotent Linear writes.**~~ `Linear.post_comment_idempotent!/3`
  embeds a deterministic marker `(identifier, attempt_n, turn_n)` as an
  HTML comment; on replay it searches the issue's comments first and
  reuses the prior id if the marker is found.
- ~~**Workspace locality.**~~ `Workspace.path_for/2` runs inside `ctx.run`
  (pure, journal-safe); `Workspace.preflight_local!/1` runs outside on
  every execution (incl. replays), so cross-node resumes always see the
  cwd codex needs.
- ~~**WORKFLOW.md hot-reload.**~~ Workflow content is read inside the
  `RunAttemptWorkflow`'s first `ctx.run`, so its bytes are pinned per
  attempt. Editing WORKFLOW.md affects new attempts only.

## Resolved in slice 3

- ~~**Codex turn awaitable boundary.**~~ `CodexTurnService` is a
  Restate Service whose `run/2` handler wraps `Codex.Manager.run_turn/6`
  in a single `ctx.run`. `RunAttemptWorkflow` calls it via
  `Context.call_async/5`, getting a durable handle.
- ~~**Stall detection.**~~ `Awaitable.any([turn_handle, ctx.timer(stall_timeout_ms)])`
  in `RunAttemptWorkflow.run_turn_with_stall_detection/8`. Stall timeout
  pulled from `codex.stall_timeout_ms` in WORKFLOW.md (default 5 min).
- ~~**Per-project poll loop.**~~ `SchedulerVO.tick/2` self-reschedules
  via `ctx.send_async(self, "tick", nil, invoke_at_ms: now + interval_ms)`.
  Suspends to ~$0 between ticks (no process held). `running` flag in VO
  state lets `stop` halt the chain on the next tick boundary.
- ~~**Reconciliation across N issues.**~~ `SchedulerVO.reconcile/2` lists
  the project's issues, fans out `IssueVO.read_state` calls via
  `Context.call_async/5`, and gathers the snapshot via
  `Restate.Awaitable.all/2` — wall time is one Restate round-trip,
  not N.

## Resolved in slice 5

- ~~**Demo-able chaos.**~~ `scripts/chaos/` + `mix symphony.chaos`
  give the operator one-line triggers for the three failure beats.
  Each script prints a banner naming what it kills and what to
  watch on the dashboard, so the audience can follow without
  reading the doc.
- ~~**Local stack reproducibility.**~~ Root `docker-compose.yml`
  pins Restate 1.6.2 (matched to `restate-elixir`'s test version);
  `scripts/dev/up.sh` waits for the admin API health-check before
  returning, so the operator never tries to register against a
  not-yet-ready Restate.
- ~~**Operator narrative.**~~ `docs/demo-script.md` — three beats,
  each tied to a specific architectural invariant from the
  `SPEC.md` mapping table. Wrap-up reframes the demo as
  "Symphony said the orchestrator state isn't restored; we
  killed three things and it was."

## Resolved in slice 4

- ~~**Operator visibility.**~~ Phoenix LiveView dashboard at
  `http://localhost:4000` (started by `mix run --no-halt` alongside
  the Restate handler endpoint). One page, 2 s auto-refresh via
  `Process.send_after(:refresh)`. Reads `SchedulerVO.reconcile`,
  `IssueVO.readState`, `RunAttemptWorkflow.readState` over the
  same Restate ingress that any other client uses — keeps the
  "Restate is the source of truth" story honest.
- ~~**Per-attempt conversation visibility.**~~
  `RunAttemptWorkflow.read_state` shared handler exposes
  `workflow_content_hash`, `workspace_path`, `conversation`,
  `turn_count`, `last_comment_id`. The dashboard fetches it
  lazily on row expand and re-fetches every refresh while the
  row stays open.
- ~~**Co-star visibility.**~~ The dashboard itself is the
  Phoenix half of the BEAM/Restate co-star pitch — it reads
  Restate-owned durable state through Restate's own protocol,
  using OTP-supervised LiveView processes for the live UI.
