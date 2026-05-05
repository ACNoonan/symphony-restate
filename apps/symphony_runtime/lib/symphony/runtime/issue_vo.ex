defmodule Symphony.Runtime.IssueVO do
  @moduledoc """
  Per-issue Restate Virtual Object. Keyed by Linear issue identifier
  (e.g. `"SYM-1"`).

  Single handler in slice 1: `dispatch/2` runs one full cycle —
  load workflow, fetch issue, render prompt, run one (stub) codex
  turn, post comment back. Every external side effect is wrapped in
  `Restate.Context.run/2` so the journal is the durable record of
  the run.

  The single-writer guarantee on the `:exclusive` handler makes the
  `claim_status` state field a trivially-correct claim guard:
  re-invoking `dispatch` while one is already running just sees the
  existing state and bails.

  ## Slice 1 vs later

  Slice 1 inlines the run-attempt logic directly. Slice 2 will
  extract a separate `Symphony.Runtime.RunAttemptWorkflow` (Restate
  Workflow service type) and add the `max_turns` continuation loop +
  `Codex.Session` OTP supervisor. The codex turn here is a
  deterministic stub; real codex stdio integration ships in slice
  1.5 / slice 2.
  """

  require Logger

  alias Restate.Context
  alias Symphony.Core.{Prompt, Workflow}
  alias Symphony.Runtime.Linear

  @doc "Restate handler. Input is ignored; state lives in the VO."
  def dispatch(%Context{} = ctx, _input) do
    identifier = Context.key(ctx)
    Logger.metadata(issue_identifier: identifier)

    case Context.get_state(ctx, "claim_status") do
      "running" ->
        %{ok: false, reason: "already_running", identifier: identifier}

      "done" ->
        %{ok: false, reason: "already_done", identifier: identifier}

      _ ->
        Context.set_state(ctx, "claim_status", "running")
        run_attempt(ctx, identifier)
    end
  end

  defp run_attempt(ctx, identifier) do
    workflow_path = Application.fetch_env!(:symphony_runtime, :workflow_path)

    {workflow_config, prompt_template} =
      Context.run(ctx, fn ->
        case Workflow.load(workflow_path) do
          {:ok, %{config: config, prompt_template: tmpl}} ->
            {config, tmpl}

          {:error, reason} ->
            raise Restate.TerminalError,
              code: 500,
              message: "workflow_load_failed: #{inspect(reason)}"
        end
      end)

    issue =
      Context.run(ctx, fn ->
        Linear.fetch_issue!(identifier)
      end)

    rendered_prompt =
      Context.run(ctx, fn ->
        case Prompt.render(prompt_template, %{issue: issue, attempt: nil}) do
          {:ok, p} ->
            p

          {:error, reason} ->
            raise Restate.TerminalError,
              code: 500,
              message: "prompt_render_failed: #{inspect(reason)}"
        end
      end)

    turn_output =
      Context.run(ctx, fn ->
        stub_codex_turn(rendered_prompt, workflow_config)
      end)

    comment_id =
      Context.run(ctx, fn ->
        Linear.post_comment!(issue.id, turn_output)
      end)

    Context.set_state(ctx, "turn_count", 1)
    Context.set_state(ctx, "last_comment_id", comment_id)
    Context.set_state(ctx, "claim_status", "done")

    %{
      ok: true,
      identifier: identifier,
      issue_id: issue.id,
      comment_id: comment_id,
      turn: 1
    }
  end

  # Slice 1.0 stub. Replaced in slice 1.5 with a real codex
  # `app-server` stdio session owned by an OTP-supervised
  # `Codex.Session` GenServer (see docs/architecture.md). The stub
  # is deterministic so replays through `ctx.run` are stable.
  defp stub_codex_turn(prompt, _config) do
    """
    [symphony-restate slice-1 stub]
    Real codex `app-server` integration lands in slice 1.5. For now,
    this is what the agent would have received as its initial turn.

    --- prompt ---
    #{prompt}
    --- end prompt ---

    Stub response: acknowledged. (Replace with real codex turn output
    once the stdio session is wired up.)
    """
    |> String.trim()
  end
end
