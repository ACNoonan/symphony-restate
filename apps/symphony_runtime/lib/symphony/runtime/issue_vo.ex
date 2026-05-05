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
  alias Symphony.Runtime.Codex.{AppServer, Workspace}

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
    workspace_root = Application.fetch_env!(:symphony_runtime, :workspace_root)

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

    workspace =
      Context.run(ctx, fn ->
        Workspace.ensure!(issue, workspace_root)
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
        codex_turn!(workspace, rendered_prompt, issue, workflow_config)
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

  defp codex_turn!(workspace, prompt, issue, workflow_config) do
    opts = codex_opts_from_config(workflow_config)
    issue_meta = %{identifier: issue.identifier, title: issue.title || ""}

    case AppServer.run(workspace, prompt, issue_meta, opts) do
      {:ok, %{text: text}} when text != "" ->
        text

      {:ok, %{text: ""}} ->
        # Codex completed without emitting any text we recognized.
        # Surface a useful message rather than posting an empty comment.
        "[symphony-restate] codex turn completed without an extractable agent message; check Restate journal for raw events."

      {:error, reason} ->
        raise Restate.TerminalError,
          code: 500,
          message: "codex_turn_failed: #{inspect(reason)}"
    end
  end

  defp codex_opts_from_config(%{"codex" => codex}) when is_map(codex) do
    []
    |> maybe_put(codex, "command", :codex_command)
    |> maybe_put(codex, "approval_policy", :approval_policy)
    |> maybe_put(codex, "thread_sandbox", :thread_sandbox)
    |> maybe_put(codex, "turn_sandbox_policy", :turn_sandbox_policy)
    |> maybe_put(codex, "turn_timeout_ms", :turn_timeout_ms)
    |> maybe_put(codex, "read_timeout_ms", :read_timeout_ms)
  end

  defp codex_opts_from_config(_), do: []

  defp maybe_put(opts, source, source_key, dest_key) do
    case Map.get(source, source_key) do
      nil -> opts
      value -> Keyword.put(opts, dest_key, value)
    end
  end
end
