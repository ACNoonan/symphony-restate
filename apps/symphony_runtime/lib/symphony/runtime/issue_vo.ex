defmodule Symphony.Runtime.IssueVO do
  @moduledoc """
  Per-issue Restate Virtual Object. Keyed by Linear issue identifier.

  Slice 2 lifecycle:

    1. Claim guard via VO state (`claim_status`).
    2. Load WORKFLOW.md, fetch issue, ensure workspace (each via
       `ctx.run` — durable side effects).
    3. Run the `1..max_turns` turn loop. Each turn:
       a. Render prompt (with `attempt: N` for continuations).
       b. Drive `Codex.Manager.run_turn/6`. Manager finds/spawns a
          long-lived `Codex.Session` for this issue on the current
          BEAM node; the Session keeps the codex port + thread hot
          across turns. Cross-node failover is handled inside the
          Session via cold-path conversation seeding from the
          durable `conversation` state below.
       c. Append `%{turn, prompt, response}` to `conversation` state
          and write back via `ctx.set_state/3`.
       d. Post a Linear comment with the turn output.
       e. Re-fetch the issue from Linear (`SPEC.md` §8.5 reconcile
          parity). If the tracker state is now terminal, break.
    4. Stop the local Session, mark `claim_status = "done"`.

  ## Co-star handoff

  Restate routes this VO to whichever node is healthy. On the active
  node, `Codex.Manager` finds an OTP-supervised Session for this
  issue keyed by identifier. When the BEAM dies, the Session dies
  with it; Restate retries the invocation on a different node;
  `Codex.Manager` there spawns a fresh Session; the Session's
  cold-path seeding rehydrates codex from `conversation` state.
  Both substrates are visible: OTP supervises the hot port, Restate
  supervises the durable state + cross-node movement.
  """

  require Logger

  alias Restate.Context
  alias Symphony.Core.{Prompt, Workflow}
  alias Symphony.Runtime.Linear
  alias Symphony.Runtime.Codex.{Manager, Workspace}

  @default_max_turns 20

  @default_terminal_states ~w(done closed cancelled canceled duplicate)

  @doc "Restate handler. Drives one full attempt of the turn loop."
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
        Context.set_state(ctx, "worker_node", to_string(node()))

        try do
          run_attempt(ctx, identifier)
        rescue
          e ->
            Context.set_state(ctx, "claim_status", "failed")
            reraise e, __STACKTRACE__
        end
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
            terminal!("workflow_load_failed", reason)
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

    max_turns = get_in(workflow_config, ["agent", "max_turns"]) || @default_max_turns
    terminal_states = terminal_states_from_config(workflow_config)
    codex_opts = codex_opts_from_config(workflow_config)

    final =
      Enum.reduce_while(1..max_turns, %{issue: issue, conversation: []}, fn turn_n, acc ->
        run_one_turn(ctx, identifier, workspace, prompt_template, codex_opts, terminal_states, max_turns, turn_n, acc)
      end)

    Context.run(ctx, fn ->
      Manager.stop_session(identifier)
      :ok
    end)

    Context.set_state(ctx, "claim_status", "done")

    final
  end

  defp run_one_turn(ctx, identifier, workspace, prompt_template, codex_opts, terminal_states, max_turns, turn_n, acc) do
    attempt = if turn_n == 1, do: nil, else: turn_n

    prompt =
      Context.run(ctx, fn ->
        case Prompt.render(prompt_template, %{issue: acc.issue, attempt: attempt}) do
          {:ok, p} -> p
          {:error, reason} -> terminal!("prompt_render_failed", reason)
        end
      end)

    response =
      Context.run(ctx, fn ->
        issue_meta = %{identifier: acc.issue.identifier, title: acc.issue.title || ""}

        case Manager.run_turn(identifier, workspace, prompt, acc.conversation, issue_meta, codex_opts) do
          {:ok, ""} ->
            "[symphony-restate] codex turn completed without an extractable agent message; check the Restate journal for raw events."

          {:ok, text} ->
            text

          {:error, reason} ->
            terminal!("codex_turn_failed", reason)
        end
      end)

    new_record = %{"turn" => turn_n, "prompt" => prompt, "response" => response}
    new_conversation = acc.conversation ++ [new_record]

    comment_id =
      Context.run(ctx, fn ->
        Linear.post_comment!(acc.issue.id, format_turn_comment(turn_n, max_turns, response))
      end)

    Context.set_state(ctx, "conversation", new_conversation)
    Context.set_state(ctx, "turn_count", turn_n)
    Context.set_state(ctx, "last_comment_id", comment_id)

    cond do
      turn_n >= max_turns ->
        {:halt,
         %{
           ok: true,
           identifier: identifier,
           issue_id: acc.issue.id,
           turns: turn_n,
           ended_by: :max_turns
         }}

      true ->
        refreshed =
          Context.run(ctx, fn ->
            Linear.fetch_issue!(identifier)
          end)

        if String.downcase(refreshed.state || "") in terminal_states do
          {:halt,
           %{
             ok: true,
             identifier: identifier,
             issue_id: acc.issue.id,
             turns: turn_n,
             ended_by: :tracker_terminal,
             final_state: refreshed.state
           }}
        else
          {:cont, %{issue: refreshed, conversation: new_conversation}}
        end
    end
  end

  defp terminal!(label, reason) do
    raise Restate.TerminalError,
      code: 500,
      message: "#{label}: #{inspect(reason)}"
  end

  defp terminal_states_from_config(config) do
    case get_in(config, ["tracker", "terminal_states"]) do
      list when is_list(list) -> Enum.map(list, &String.downcase/1)
      _ -> @default_terminal_states
    end
  end

  defp format_turn_comment(turn_n, max_turns, text) do
    """
    🎼 **symphony-restate — turn #{turn_n}/#{max_turns}**

    #{text}
    """
    |> String.trim()
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
