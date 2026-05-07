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
  @workflow_cancel_handler "cancel"
  @workflow_nudge_handler "nudge"
  @workflow_nudge_now_handler "nudge_now"

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
            Context.set_state(ctx, "claim_status", terminal_claim_status(e))
            reraise e, __STACKTRACE__
        end
    end
  end

  @doc """
  Shared handler. Forwards the cancel request to the active
  attempt's `RunAttemptWorkflow.cancel`. Runs concurrently with
  any in-flight `dispatch/2` (single-writer doesn't apply to
  shared handlers); does not mutate VO state itself.
  """
  def cancel(%Context{} = ctx, _input) do
    identifier = Context.key(ctx)

    case Context.get_state(ctx, "last_attempt_n") do
      n when is_integer(n) and n > 0 ->
        case Context.get_state(ctx, "claim_status") do
          "running" ->
            workflow_key = attempt_workflow_key(identifier, n)

            Context.call(ctx, @workflow_service, @workflow_cancel_handler, nil, key: workflow_key)
            |> wrap_cancel_result(identifier, n)

          status ->
            %{
              "ok" => false,
              "reason" => "not_running",
              "claim_status" => status,
              "identifier" => identifier
            }
        end

      _ ->
        %{
          "ok" => false,
          "reason" => "no_attempt",
          "identifier" => identifier
        }
    end
  end

  defp wrap_cancel_result(%{"ok" => true} = workflow_resp, identifier, n) do
    Map.merge(workflow_resp, %{"identifier" => identifier, "attempt_n" => n})
  end

  defp wrap_cancel_result(%{"ok" => false} = workflow_resp, identifier, n) do
    Map.merge(workflow_resp, %{"identifier" => identifier, "attempt_n" => n})
  end

  defp wrap_cancel_result(other, identifier, n) do
    %{
      "ok" => false,
      "reason" => "unexpected_workflow_response",
      "details" => other,
      "identifier" => identifier,
      "attempt_n" => n
    }
  end

  @doc """
  Shared handler. Operator interjection for the active attempt.
  Forwards the message to the active workflow's `nudge` handler;
  the message is durably stored and prepended to the next turn's
  prompt.
  """
  def nudge(%Context{} = ctx, %{"text" => text} = input)
      when is_binary(text) and text != "" do
    identifier = Context.key(ctx)

    case Context.get_state(ctx, "last_attempt_n") do
      n when is_integer(n) and n > 0 ->
        case Context.get_state(ctx, "claim_status") do
          "running" ->
            workflow_key = attempt_workflow_key(identifier, n)

            ctx
            |> Context.call(@workflow_service, @workflow_nudge_handler, %{"text" => text},
              key: workflow_key
            )
            |> wrap_nudge_result(identifier, n, input)

          status ->
            %{
              "ok" => false,
              "reason" => "not_running",
              "claim_status" => status,
              "identifier" => identifier
            }
        end

      _ ->
        %{
          "ok" => false,
          "reason" => "no_attempt",
          "identifier" => identifier
        }
    end
  end

  def nudge(%Context{} = ctx, _other) do
    %{
      "ok" => false,
      "reason" => "missing_or_empty_text",
      "identifier" => Context.key(ctx)
    }
  end

  defp wrap_nudge_result(%{"ok" => _} = workflow_resp, identifier, n, _input) do
    Map.merge(workflow_resp, %{"identifier" => identifier, "attempt_n" => n})
  end

  defp wrap_nudge_result(other, identifier, n, _input) do
    %{
      "ok" => false,
      "reason" => "unexpected_workflow_response",
      "details" => other,
      "identifier" => identifier,
      "attempt_n" => n
    }
  end

  @doc """
  Shared handler. Mid-turn operator interjection — the in-flight
  turn is abandoned (port killed, an awakeable wakes the workflow's
  per-turn race) and the operator's text is durably staged for the
  next turn's prompt. Costs the in-flight turn's tokens; the trade
  is sub-second responsiveness vs. waiting for the current turn to
  finish.
  """
  def nudge_now(%Context{} = ctx, %{"text" => text} = input)
      when is_binary(text) and text != "" do
    identifier = Context.key(ctx)

    case Context.get_state(ctx, "last_attempt_n") do
      n when is_integer(n) and n > 0 ->
        case Context.get_state(ctx, "claim_status") do
          "running" ->
            workflow_key = attempt_workflow_key(identifier, n)

            ctx
            |> Context.call(@workflow_service, @workflow_nudge_now_handler, %{"text" => text},
              key: workflow_key
            )
            |> wrap_nudge_result(identifier, n, input)

          status ->
            %{
              "ok" => false,
              "reason" => "not_running",
              "claim_status" => status,
              "identifier" => identifier
            }
        end

      _ ->
        %{
          "ok" => false,
          "reason" => "no_attempt",
          "identifier" => identifier
        }
    end
  end

  def nudge_now(%Context{} = ctx, _other) do
    %{
      "ok" => false,
      "reason" => "missing_or_empty_text",
      "identifier" => Context.key(ctx)
    }
  end

  defp terminal_claim_status(%Restate.TerminalError{code: 409}), do: "cancelled"

  defp terminal_claim_status(%Restate.TerminalError{message: msg}) when is_binary(msg) do
    if String.contains?(msg, "cancelled_by_operator"), do: "cancelled", else: "failed"
  end

  defp terminal_claim_status(_), do: "failed"

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
