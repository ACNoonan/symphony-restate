defmodule Symphony.Runtime.RunAttemptWorkflow do
  @moduledoc """
  Per-attempt Restate Workflow. One workflow key = one run attempt
  for one issue. Keyed by `"\#{identifier}::a\#{attempt_n}"` so a
  re-dispatch of the same issue gets a fresh workflow key, while
  any cross-node retry of *the same* attempt resumes the existing
  journal.

  ## Why this is a Workflow, not part of `IssueVO`

  Slice 2 ran the `1..max_turns` loop inline in `IssueVO.dispatch`.
  That worked but conflated three concerns:

    * the *claim* (single-writer per issue id) — VO concern
    * the *attempt journal* (one specific run of the agent over
      the issue, with conversation, turn count, comment ids, the
      pinned WORKFLOW.md content) — Workflow concern
    * cross-node failover for the attempt — already free under VO,
      but better expressed at the Workflow level so the IssueVO can
      observe terminal failures without itself rolling back

  By extracting the attempt loop into a Workflow, an external
  observer (`Symphony.Runtime.RunAttemptWorkflow.read_state/1`,
  the LiveView dashboard in slice 4, the cancellation path in
  slice 3) can address a specific attempt by key — separate from
  the issue's lifetime.

  ## Workflow content pin (`SPEC.md` §6.2 mapping)

  WORKFLOW.md is treated as a deployment artifact, not a live-
  reload source. The first thing this workflow does is read
  WORKFLOW.md inside `ctx.run`. The loaded content is journaled,
  so any re-execution of *this* attempt sees the same bytes the
  first attempt saw — even if WORKFLOW.md was edited on disk
  between failover and resume. A fresh attempt (new key) reads
  the current bytes.

  The content hash is also stored in workflow state for
  observability — operators can ask "which version of WORKFLOW.md
  did this attempt run against?" without having to scrape the
  journal.

  ## State schema (string keys, JSON-safe)

    * `"workflow_content_hash"` — sha256 of WORKFLOW.md content
      as loaded on first execution; pinned for the attempt
    * `"workspace_path"` — absolute path of the per-issue
      workspace directory
    * `"conversation"` — list of `%{"turn", "prompt", "response"}`
      maps; appended after each successful turn
    * `"turn_count"` — most recent turn number completed
    * `"last_comment_id"` — Linear comment id from the most
      recent turn

  ## Input / output

  Input (from `IssueVO.dispatch`):

      %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/abs/path/WORKFLOW.md",
        "workspace_root" => "/abs/path/workspaces"
      }

  Output (returned to `IssueVO.dispatch`):

      %{
        "ok" => true,
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "issue_id" => "uuid",
        "turns" => 7,
        "ended_by" => "tracker_terminal" | "max_turns",
        "final_state" => "Done",          # only when tracker_terminal
        "workflow_content_hash" => "abc..."
      }
  """

  require Logger

  alias Restate.Context
  alias Symphony.Core.{Issue, Prompt, Workflow}
  alias Symphony.Runtime.Linear
  alias Symphony.Runtime.Codex.{Manager, Workspace}

  @default_max_turns 20
  @default_terminal_states ~w(done closed cancelled canceled duplicate)

  @doc "Workflow `run` handler. One-shot per workflow key."
  def run(%Context{} = ctx, input) when is_map(input) do
    identifier = require_string!(input, "identifier")
    attempt_n = require_pos_integer!(input, "attempt_n")
    workflow_path = require_string!(input, "workflow_path")
    workspace_root = require_string!(input, "workspace_root")

    Logger.metadata(issue_identifier: identifier, attempt_n: attempt_n)

    {workflow_config, prompt_template, content_hash} =
      load_workflow_pinned(ctx, workflow_path)

    Context.set_state(ctx, "workflow_content_hash", content_hash)

    issue_map = fetch_issue(ctx, identifier)

    workspace_path =
      Context.run(ctx, fn ->
        Workspace.path_for(struct(Issue, atomize(issue_map)), workspace_root)
      end)

    # Outside ctx.run on purpose: the journaled path may have been
    # created on a different BEAM node, so preflight every execution
    # (incl. replays) on whichever node currently holds the invocation.
    Workspace.preflight_local!(workspace_path)
    Context.set_state(ctx, "workspace_path", workspace_path)

    max_turns = get_in(workflow_config, ["agent", "max_turns"]) || @default_max_turns
    terminal_states = terminal_states_from_config(workflow_config)
    codex_opts = codex_opts_from_config(workflow_config)

    final =
      Enum.reduce_while(1..max_turns, %{"issue" => issue_map, "conversation" => []}, fn turn_n,
                                                                                        acc ->
        run_one_turn(
          ctx,
          %{
            identifier: identifier,
            attempt_n: attempt_n,
            workspace_path: workspace_path,
            prompt_template: prompt_template,
            codex_opts: codex_opts,
            terminal_states: terminal_states,
            max_turns: max_turns,
            turn_n: turn_n
          },
          acc
        )
      end)

    Context.run(ctx, fn ->
      Manager.stop_session(identifier)
      :ok
    end)

    Map.put(final, "workflow_content_hash", content_hash)
  end

  # ---------------------- Workflow steps ----------------------

  # Load + parse WORKFLOW.md inside ctx.run so the content + parsed
  # config are journaled (the pin from `SPEC.md` §6.2). Returns
  # plain JSON-decodable shapes — no tuples, no structs.
  defp load_workflow_pinned(ctx, workflow_path) do
    pinned =
      Context.run(ctx, fn ->
        case File.read(workflow_path) do
          {:ok, raw} ->
            hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

            case Workflow.parse(raw) do
              {:ok, %{config: config, prompt_template: tmpl}} ->
                %{"config" => config, "prompt_template" => tmpl, "content_hash" => hash}

              {:error, reason} ->
                terminal!("workflow_parse_failed", reason)
            end

          {:error, reason} ->
            terminal!("workflow_load_failed", {workflow_path, reason})
        end
      end)

    {pinned["config"], pinned["prompt_template"], pinned["content_hash"]}
  end

  defp fetch_issue(ctx, identifier) do
    Context.run(ctx, fn ->
      identifier
      |> Linear.fetch_issue!()
      |> Map.from_struct()
      |> stringify_keys()
    end)
  end

  defp run_one_turn(ctx, ctx_args, acc) do
    %{
      identifier: identifier,
      attempt_n: attempt_n,
      workspace_path: workspace_path,
      prompt_template: prompt_template,
      codex_opts: codex_opts,
      terminal_states: terminal_states,
      max_turns: max_turns,
      turn_n: turn_n
    } = ctx_args

    attempt_label = if turn_n == 1, do: nil, else: turn_n

    prompt =
      Context.run(ctx, fn ->
        case Prompt.render(prompt_template, %{issue: acc["issue"], attempt: attempt_label}) do
          {:ok, p} -> p
          {:error, reason} -> terminal!("prompt_render_failed", reason)
        end
      end)

    response =
      Context.run(ctx, fn ->
        issue_meta = %{
          identifier: acc["issue"]["identifier"],
          title: acc["issue"]["title"] || ""
        }

        conversation_for_session =
          Enum.map(acc["conversation"], fn rec ->
            %{
              turn: rec["turn"],
              prompt: rec["prompt"],
              response: rec["response"]
            }
          end)

        case Manager.run_turn(
               identifier,
               workspace_path,
               prompt,
               conversation_for_session,
               issue_meta,
               codex_opts
             ) do
          {:ok, ""} ->
            "[symphony-restate] codex turn completed without an extractable agent message; check the Restate journal for raw events."

          {:ok, text} ->
            text

          {:error, reason} ->
            terminal!("codex_turn_failed", reason)
        end
      end)

    new_record = %{"turn" => turn_n, "prompt" => prompt, "response" => response}
    new_conversation = acc["conversation"] ++ [new_record]

    comment_id =
      Context.run(ctx, fn ->
        marker = Linear.attempt_turn_marker(identifier, attempt_n, turn_n)
        body = format_turn_comment(turn_n, max_turns, response, marker)

        Linear.post_comment_idempotent!(acc["issue"]["id"], body, marker)
      end)

    Context.set_state(ctx, "conversation", new_conversation)
    Context.set_state(ctx, "turn_count", turn_n)
    Context.set_state(ctx, "last_comment_id", comment_id)

    cond do
      turn_n >= max_turns ->
        {:halt,
         %{
           "ok" => true,
           "identifier" => identifier,
           "attempt_n" => attempt_n,
           "issue_id" => acc["issue"]["id"],
           "turns" => turn_n,
           "ended_by" => "max_turns"
         }}

      true ->
        refreshed = fetch_issue(ctx, identifier)

        if String.downcase(refreshed["state"] || "") in terminal_states do
          {:halt,
           %{
             "ok" => true,
             "identifier" => identifier,
             "attempt_n" => attempt_n,
             "issue_id" => acc["issue"]["id"],
             "turns" => turn_n,
             "ended_by" => "tracker_terminal",
             "final_state" => refreshed["state"]
           }}
        else
          {:cont, %{"issue" => refreshed, "conversation" => new_conversation}}
        end
    end
  end

  # ---------------------- Helpers ----------------------

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

  defp format_turn_comment(turn_n, max_turns, text, marker) do
    """
    🎼 **symphony-restate — turn #{turn_n}/#{max_turns}**

    #{text}

    <!-- #{marker} -->
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

  defp require_string!(input, key) do
    case Map.get(input, key) do
      v when is_binary(v) and v != "" -> v
      other -> terminal!("invalid_workflow_input", {key, other})
    end
  end

  defp require_pos_integer!(input, key) do
    case Map.get(input, key) do
      v when is_integer(v) and v > 0 -> v
      other -> terminal!("invalid_workflow_input", {key, other})
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(other), do: other

  defp atomize(%{} = map) do
    # Best-effort coerce a JSON-decoded issue map back to atom-keyed
    # for `Workspace.path_for` (which takes an `Issue` struct via
    # struct/2). Only the keys we actually need.
    %{
      id: map["id"],
      identifier: map["identifier"],
      title: map["title"],
      description: map["description"],
      priority: map["priority"],
      state: map["state"],
      branch_name: map["branch_name"] || map["branchName"],
      url: map["url"],
      labels: map["labels"] || [],
      blocked_by: map["blocked_by"] || [],
      created_at: map["created_at"] || map["createdAt"],
      updated_at: map["updated_at"] || map["updatedAt"]
    }
  end
end
