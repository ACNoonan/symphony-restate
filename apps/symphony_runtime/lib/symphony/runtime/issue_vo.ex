defmodule Symphony.Runtime.IssueVO do
  @moduledoc """
  Per-issue Restate Virtual Object. Keyed by Linear issue identifier.

  ## Slice 2.5 dispatch shape

  After slice 2.5, `IssueVO` is a thin claim/dispatcher. It owns
  the *claim* (single-writer per issue id) but does not own the
  attempt journal — that lives in `RunAttemptWorkflow`, keyed by
  `"\#{identifier}::a\#{attempt_n}"`.

  Each `dispatch/2` invocation:

    1. Reads `claim_status` from VO state. If already `running` or
       `done`, refuses (slice 2 behavior preserved — the demo's
       chaos beats are about Restate retrying *one* dispatch
       across nodes, not about dispatching twice from outside).
    2. Increments `last_attempt_n` and records `worker_node` for
       observability. The attempt number is part of the workflow
       key, so a re-`dispatch` of the same issue (after a previous
       attempt finishes or fails) gets a fresh workflow journal.
    3. Synchronously calls `RunAttemptWorkflow.run` via
       `Restate.Context.call/5`. The workflow does the entire
       turn loop (`SPEC.md` §7.2). On Restate-level retry of
       this VO invocation across nodes, the call is journaled —
       the second execution returns the workflow's recorded
       result without re-invoking it.
    4. On success → `claim_status="done"`. On
       `Restate.TerminalError` → `claim_status="failed"` and the
       error propagates back to the dispatcher.

  ## Co-star handoff

  Restate routes this VO to whichever node is healthy. The
  workflow-level orchestration also routes to whichever node is
  healthy (independent decision). On the active workflow node,
  `Codex.Manager` finds-or-spawns the OTP-supervised
  `Codex.Session` for this issue id; cross-node failover is
  handled inside the Session via cold-path conversation seeding
  from the workflow's durable `conversation` state.
  """

  require Logger

  alias Restate.Context

  @workflow_service "RunAttemptWorkflow"
  @workflow_handler "run"

  @doc """
  Restate handler. Returns a snapshot of this VO's state so an
  external orchestrator (the `SchedulerVO` reconciliation path,
  the LiveView dashboard in slice 4) can read claim status without
  triggering a fresh dispatch. JSON-safe map; missing keys come
  back as `nil`.
  """
  def read_state(%Context{} = ctx, _input) do
    identifier = Context.key(ctx)

    %{
      "identifier" => identifier,
      "claim_status" => Context.get_state(ctx, "claim_status"),
      "last_attempt_n" => Context.get_state(ctx, "last_attempt_n"),
      "last_attempt_result" => Context.get_state(ctx, "last_attempt_result"),
      "worker_node" => Context.get_state(ctx, "worker_node")
    }
  end

  @doc "Restate handler. Dispatches one new attempt for this issue."
  def dispatch(%Context{} = ctx, _input) do
    identifier = Context.key(ctx)
    Logger.metadata(issue_identifier: identifier)

    case Context.get_state(ctx, "claim_status") do
      "running" ->
        %{"ok" => false, "reason" => "already_running", "identifier" => identifier}

      "done" ->
        %{"ok" => false, "reason" => "already_done", "identifier" => identifier}

      _ ->
        attempt_n = (Context.get_state(ctx, "last_attempt_n") || 0) + 1
        Context.set_state(ctx, "last_attempt_n", attempt_n)
        Context.set_state(ctx, "claim_status", "running")
        Context.set_state(ctx, "worker_node", to_string(node()))

        try do
          result = run_attempt_via_workflow(ctx, identifier, attempt_n)
          Context.set_state(ctx, "claim_status", "done")
          Context.set_state(ctx, "last_attempt_result", result)
          result
        rescue
          e in Restate.TerminalError ->
            Context.set_state(ctx, "claim_status", "failed")
            reraise e, __STACKTRACE__
        end
    end
  end

  defp run_attempt_via_workflow(ctx, identifier, attempt_n) do
    workflow_path = Application.fetch_env!(:symphony_runtime, :workflow_path)
    workspace_root = Application.fetch_env!(:symphony_runtime, :workspace_root)

    input = %{
      "identifier" => identifier,
      "attempt_n" => attempt_n,
      "workflow_path" => workflow_path,
      "workspace_root" => workspace_root
    }

    Context.call(ctx, @workflow_service, @workflow_handler, input,
      key: attempt_workflow_key(identifier, attempt_n)
    )
  end

  @doc false
  @spec attempt_workflow_key(String.t(), pos_integer()) :: String.t()
  def attempt_workflow_key(identifier, attempt_n)
      when is_binary(identifier) and is_integer(attempt_n) do
    "#{identifier}::a#{attempt_n}"
  end
end
