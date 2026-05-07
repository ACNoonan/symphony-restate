# symphony-restate — demo script

Slice 5. The narrative the operator runs from. Three chaos beats,
each one zeroed in on a single architectural invariant from
`docs/architecture.md`.

The point of the demo is not "AI agent fixes Linear ticket" — it's
*"Symphony's published `SPEC.md` openly says the in-memory orchestrator
state is not restored on restart; here's the substrate where it is."*
Every beat is a different way of putting pressure on that claim.

## Prereqs

- `docker` + `docker compose`
- `mix` 1.18+, Erlang/OTP 28+
- `LINEAR_API_KEY` in env
- `codex` CLI on PATH (the same `codex app-server` upstream Symphony uses)
- `WORKFLOW.md` edited so `tracker.project_slug` points at a real Linear
  project with at least one issue in an `active_states` state (default:
  `Todo` / `In Progress`)

## Booting the stack

Four shells. (You can collapse 2 + 3 into one with `&` if you have a
big terminal, but four is easier to point at.)

```sh
# 1. Restate (single node, in Docker)
./scripts/dev/up.sh

# 2. BEAM (handlers + LiveView dashboard, on the host)
mix run --no-halt

# 3. Endpoint registration — once after the BEAM is up
./scripts/dev/register.sh

# 4. The poll loop
mix symphony.scheduler start <PROJECT_SLUG> --interval 30000 --exec
```

Open the dashboard: <http://localhost:4000>

You should see, within ~2 s of refresh:

- `scheduler · ok ✓ · issues seen: N`
- A row per active issue, each with `claim` flipping `unclaimed → running`
  as the scheduler ticks
- Click any row to expand → conversation panel populates as turns finish

That's the steady state. From here, the beats.

---

## Beat 1 — codex port dies

**Architectural invariant:** *"No durable illusion around ports. A
`Codex.Session` may die at any time. Durable state must be sufficient
to restart on a different BEAM node."*

**Trigger:**

```sh
mix symphony.chaos kill_codex
```

(Or `./scripts/chaos/kill-codex.sh` directly.)

**What happens under the hood:**

1. `Codex.Session.handle_info({port, {:exit_status, _}}, ...)` catches
   the port exit and stops the GenServer (transient — DynamicSupervisor
   does not restart).
2. The currently in-flight `CodexTurnService.run` invocation returns
   `{:error, {:port_exit, _}}` from `Manager.run_turn/6`,
   `CodexTurnService` raises `Restate.TerminalError` for the failed
   turn.
3. `RunAttemptWorkflow`'s `Awaitable.any([turn_handle, stall_timer])`
   resolves on the turn handle with the terminal error → workflow
   raises `codex_turn_failed`. `IssueVO.dispatch` catches and sets
   `claim_status="failed"`.
4. **The next scheduler tick** (or a manual `mix symphony.dispatch`)
   re-dispatches the issue. `IssueVO` increments `last_attempt_n`,
   spawns a fresh `RunAttemptWorkflow` keyed `${id}::a${new_n}`. That
   workflow's first turn spawns a fresh `Codex.Session`. The Session
   sees `expected_completed_turns == 0` initially, but the workflow
   passes its (empty for a brand-new attempt) conversation. If you
   want to demo cold-path seeding, kill codex *during* a multi-turn
   issue and let the next attempt re-dispatch — the prior attempt's
   conversation is in the *prior workflow's* state, not the new one's,
   so cold-path seeding is more visible in beat 2 (BEAM kill).

**Watch on the dashboard:**

- `claim` flips `running → failed` within one refresh
- `last_attempt_n` increments on the next dispatch
- The new attempt's row expansion shows a fresh `workflow_content_hash`
  (still pinned to the same WORKFLOW.md content unless you edited it)

**The point:** OTP supervised the live port; Restate's durable state
let the operator (or the scheduler) start a fresh attempt on cold-path
data. Neither substrate did the other's job.

---

## Beat 2 — BEAM node dies

**Architectural invariants:**
- *"Restate routes the next `IssueVO` invocation to a different node;
  this Manager on that node spawns a fresh Session; the Session's
  cold-path seeding logic re-builds codex context from `IssueVO`'s
  durable conversation state."*
- *"No node-local path in the journal unless storage is shared."*

**Setup for the beat:** make sure at least one issue is mid-attempt
with `turn_count >= 2` so the cold-path seeding is dramatic. (Easy
way: kick off a dispatch, let it run a few turns, then trigger.)

**Trigger:**

```sh
# IMPORTANT: from a *different* terminal than the one running
# `mix run --no-halt` — otherwise you cancel your own command.
./scripts/chaos/kill-beam.sh
```

**What happens under the hood:**

1. The BEAM dies. `Codex.Session` GenServers, `mix symphony.scheduler`'s
   in-flight tick (if any), the LiveView dashboard, the BEAM's
   in-flight `CodexTurnService.run` and `RunAttemptWorkflow.run`
   invocations — all gone.
2. Restate's runtime detects the in-flight invocations have stopped
   responding to keep-alives and queues them for redelivery.
3. The dashboard goes dark (you killed its host BEAM). **This is
   intentional**: it's proof that anything you're about to see when
   the dashboard comes back lived in Restate, not in BEAM memory.
4. **Restart:**
   ```sh
   mix run --no-halt
   ```
5. Restate redelivers the in-flight invocations to the new BEAM.
   `RunAttemptWorkflow.run` resumes — every completed `ctx.run` block
   is replayed from the journal (no side effects re-run). When
   execution reaches the next `CodexTurnService` `call_async`,
   `Manager.run_turn` finds no `Codex.Session` for this issue on this
   fresh BEAM, spawns one. The new Session sees `completed_turns == 0`
   but the workflow passes a non-empty `conversation_so_far`.
   `Codex.Session` prepends the **cold-path preamble** built from the
   prior turns and feeds it to codex in one extra round-trip.

**Watch on the dashboard (after restart):**

- Reload the page: `worker_node` is the new BEAM's node name.
  `claim_status` is unchanged (still `running`). `last_attempt_n` is
  unchanged.
- Expand the row. The conversation transcript is the same one that
  was visible before the kill — no turns lost.
- Watch the next turn complete. It's running on the new BEAM. The
  agent has no awareness it moved hosts.

**The point:** the OTP-supervised port is gone; the durable
conversation in the workflow's state is what made the new Session
useful.

---

## Beat 3 — Restate node dies

**Architectural invariant:** *"Restate cluster re-routes the
invocation; VO/Workflow state untouched; the call retries durably.
The OTP side never notices because the durable state didn't move."*

**Trigger:**

```sh
mix symphony.chaos kill_restate
```

**What happens under the hood:**

1. `docker kill symphony-restate` — the Restate container goes away.
2. The dashboard's next 2-second poll fails (`Symphony.Dashboard.RestateClient`
   gets `connection refused` from ingress). The header's `stale (...)`
   badge appears immediately. The dashboard keeps showing the *last
   good snapshot* — it doesn't blank out.
3. Any in-flight `ctx.send_async` from the scheduler tick chain
   queues locally on the BEAM until the connection comes back.
   In-flight `CodexTurnService` invocations that have already started
   don't notice — they're driving codex; nothing's blocking.
4. **Restart:**
   ```sh
   docker compose up -d restate
   ```
5. Restate replays its persisted journals from disk. Scheduled
   invocations whose `invoke_at_ms` has passed fire immediately;
   ones still in the future fire on schedule.
6. The dashboard's stale badge clears within ~2 s. The state matches
   what was visible before the outage.

**Watch on the dashboard:**

- `stale (restate ingress unreachable: ...)` appears in the header
  during the outage
- The issue table doesn't blank — last good snapshot stays
- The badge clears once Restate is back; new ticks resume

**The point:** the BEAM stayed up the whole time. Anything the
dashboard could show during recovery came from the Restate journal,
not BEAM memory. This is the most decisive
"Restate-is-the-source-of-truth" beat.

---

## Wrap-up — the one-line takeaway

> Symphony's `SPEC.md` says exact in-memory scheduler state is not
> restored on restart. We just killed three different things —
> codex, the whole BEAM, the Restate node — and every issue's claim,
> conversation, and attempt history survived. The orchestrator
> *state* is durable. That's the missing piece, and that's what
> Restate is.

## Reset between runs

```sh
./scripts/dev/down.sh   # nukes Restate's volumes — fresh state
./scripts/dev/up.sh
mix run --no-halt
./scripts/dev/register.sh
mix symphony.scheduler start <PROJECT_SLUG> --interval 30000 --exec
```
