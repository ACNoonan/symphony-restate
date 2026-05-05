# symphony-restate

OpenAI [Symphony](https://github.com/openai/symphony) on Restate — a durable substrate for the spec.

> **Status: pre-alpha, slice 1.5 done (2026-05-05).** Pivoted 2026-05-05. Built on
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
and Restate as co-stars. Each Linear issue maps to a Restate **Virtual Object** that
holds the durable claim state + worker-node affinity. Each run attempt is a Restate
**Workflow** invocation that journals every codex turn (input + output) via `ctx.run`.
The codex stdio session itself is owned by an **OTP-supervised `Codex.Session`
GenServer** pinned to one BEAM node — fast turn-to-turn handoff while the node is
healthy. On node death, the VO durably observes the dead-pin, dispatches the next
turn to a healthy node, which spawns a fresh `Codex.Session` and replays the
conversation from the journal. Both substrates do what they're best at.

See `docs/architecture.md` for diagrams + the full mapping against `SPEC.md`.

## Restate primitives shown

- **Virtual Object** state (per-issue claim, worker-node affinity)
- **Workflow** + durable promises (per-run-attempt, turn boundaries)
- `ctx.run` retry policies (workspace ops, codex turn I/O)
- `ctx.sleep` + scheduled invocations (poll loop, retry backoff, stall detection)
- `Awaitable.any` / `all` (turn-vs-stall race, fan-out reconciliation)
- Cancellation (terminal-state issue → cancel running run)

## Run it locally

```sh
# Prereqs: mix 1.19+, Erlang/OTP 28+, restate-server 1.6+, LINEAR_API_KEY in env.
# (Real codex stdio integration ships in slice 1.5 — slice 1 uses a deterministic
# stub turn so the durability story is testable without an OpenAI account.)
mix deps.get
mix compile

# Run the pure-layer test suite (parser + Liquid render):
cd apps/symphony_core && mix test

# Boot the BEAM endpoint on :9082 (handlers register at start):
mix run --no-halt

# In another shell, register the deployment with restate-server:
restate --yes deployments register http://localhost:9082

# Edit WORKFLOW.md → set tracker.project_slug to your Linear project slug.
# Then trigger one issue end-to-end:
mix symphony.dispatch SYM-1 --exec
```

`mix symphony.dispatch SYM-1` prints the curl, or pass `--exec` to run it. The
handler will: load WORKFLOW.md (`ctx.run`), fetch the issue from Linear (`ctx.run`),
render the prompt with Solid Liquid (`ctx.run`), produce a stub turn (`ctx.run`),
post a comment back to the Linear issue (`ctx.run`), and journal each step. Kill
the BEAM mid-flow and Restate replays past completed `ctx.run` blocks on resume.

## Demo script

`docs/demo-script.md` — TBD; lands with slice 5 (chaos beats).

## Status

| Slice | Scope | Status |
|---|---|---|
| 0 | Umbrella scaffold, Apache-2.0, deps wired | **done** |
| 1 | WORKFLOW.md parser + Liquid render in `:symphony_core`; `IssueVO.dispatch` w/ Linear fetch + post-comment + stub codex turn; `mix symphony.dispatch` task; endpoint registered on :9082 | **done (2026-05-05)** |
| 1.5 | Real `codex app-server` stdio session (single-shot port of upstream `SymphonyElixir.Codex.AppServer`); per-turn workspace ensure; auto-approval policy for non-interactive runs | **done (2026-05-05)** |
| 2 | `max_turns` continuation loop; OTP-supervised `Codex.Session`; conversation replay on respawn; extract `RunAttemptWorkflow` | not started |
| 3 | Scheduler / poll loop; reconciliation; stall detection | not started |
| 4 | Phoenix LiveView dashboard reading Restate journal | not started |
| 5 | Chaos beats (`pkill` codex / BEAM node / Restate node) | not started |

Demo readiness gate: see [`demo-engineering.md` §6](../demo-engineering.md).

## License

Apache-2.0 (matching upstream Symphony). Portions of this code are derived from
[OpenAI Symphony](https://github.com/openai/symphony); see [`NOTICE`](NOTICE) for
the per-module attribution.
