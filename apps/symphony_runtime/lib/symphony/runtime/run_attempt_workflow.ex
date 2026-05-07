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
    * `"current_cancel_awakeable_id"` — opaque awakeable id for
      the in-flight turn's cancel slot. Written on every turn
      entry; read by the `cancel/2` shared handler so an operator
      cancel completes the awakeable, which makes the per-turn
      `Awaitable.any` race wake on the cancel branch. Stale
      between turns (the next turn allocates a fresh awakeable,
      orphaning the old one — the orphan is never awaited so a
      late completion is a no-op).
    * `"current_nudge_now_awakeable_id"` — companion awakeable for
      `nudge_now/2`. Same lifecycle as the cancel awakeable but
      its branch in the race aborts the in-flight turn *and
      continues the loop* with the operator's text already staged
      in `nudge:*` state — the next turn renders it as the next
      operator interjection.

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

  alias Restate.{Awaitable, Context}
  alias Symphony.Core.{Issue, Prompt, Workflow}
  alias Symphony.Runtime.Linear
  alias Symphony.Runtime.Codex.{Manager, Workspace}

  @default_max_turns 20
  @default_terminal_states ~w(done closed cancelled canceled duplicate)
  @default_stall_timeout_ms :timer.minutes(5)
  @codex_turn_service "CodexTurnService"
  @codex_turn_handler "run"
  @nudge_state_prefix "nudge:"

  @doc """
  Shared handler. Returns a snapshot of this attempt's workflow
  state so the LiveView dashboard (slice 4) can render the
  conversation without driving anything. Workflow `:shared`
  handlers can run concurrently with `run` and with each other.
  Missing keys come back as `nil` until `run` writes them.
  """
  def read_state(%Context{} = ctx, _input) do
    %{
      "workflow_key" => Context.key(ctx),
      "workflow_content_hash" => Context.get_state(ctx, "workflow_content_hash"),
      "workspace_path" => Context.get_state(ctx, "workspace_path"),
      "conversation" => Context.get_state(ctx, "conversation") || [],
      "turn_count" => Context.get_state(ctx, "turn_count"),
      "last_comment_id" => Context.get_state(ctx, "last_comment_id")
    }
  end

  @doc """
  Shared handler. Operator interjection for the next turn of this
  attempt. Stores the message under a unique key so concurrent
  nudges don't race on the same state slot. The `run` handler
  drains all `nudge:*` keys at the top of each turn (after a
  suspending op so the state snapshot is fresh) and prepends them
  to the rendered prompt as `### Operator interjection`.

  Latency: turn-boundary. A nudge sent mid-turn is observed at the
  next turn's prompt render. For sub-second mid-turn injection see
  `nudge_now/2` (slice 5 / phase D).
  """
  def nudge(%Context{} = ctx, %{"text" => text}) when is_binary(text) and text != "" do
    key = nudge_state_key()

    Context.set_state(ctx, key, %{
      "text" => text,
      "received_at_ms" => System.os_time(:millisecond)
    })

    %{"ok" => true, "key" => key, "workflow_key" => Context.key(ctx)}
  end

  def nudge(%Context{} = ctx, _other) do
    %{
      "ok" => false,
      "reason" => "missing_or_empty_text",
      "workflow_key" => Context.key(ctx)
    }
  end

  defp nudge_state_key do
    ms = System.os_time(:millisecond)
    nonce = :rand.uniform(1_000_000)
    padded_ms = ms |> Integer.to_string() |> String.pad_leading(16, "0")
    @nudge_state_prefix <> padded_ms <> ":" <> Integer.to_string(nonce)
  end

  @doc """
  Shared handler. Mid-turn operator interjection — stages the text
  for the next turn (same as `nudge/2`) AND completes the active
  turn's `nudge_now` awakeable so the per-turn `Awaitable.any` race
  wakes immediately, abandons the in-flight turn, kills the local
  Codex.Session port, and continues the loop with the staged text.

  If no turn is currently in flight (the workflow is between turns
  or hasn't reached the first turn yet) the message is still staged;
  the next turn will pick it up. The response includes
  `"queued_only" => true` in that case so the operator UI can show
  "queued" rather than "interrupted now".
  """
  def nudge_now(%Context{} = ctx, %{"text" => text}) when is_binary(text) and text != "" do
    key = nudge_state_key()

    Context.set_state(ctx, key, %{
      "text" => text,
      "received_at_ms" => System.os_time(:millisecond),
      "via" => "nudge_now"
    })

    case Context.get_state(ctx, "current_nudge_now_awakeable_id") do
      id when is_binary(id) and id != "" ->
        Context.complete_awakeable(ctx, id, "nudge_now_redirect")

        %{
          "ok" => true,
          "interrupted" => true,
          "key" => key,
          "workflow_key" => Context.key(ctx)
        }

      _ ->
        %{
          "ok" => true,
          "interrupted" => false,
          "queued_only" => true,
          "key" => key,
          "workflow_key" => Context.key(ctx)
        }
    end
  end

  def nudge_now(%Context{} = ctx, _other) do
    %{
      "ok" => false,
      "reason" => "missing_or_empty_text",
      "workflow_key" => Context.key(ctx)
    }
  end

  @doc """
  Shared handler. Operator-initiated cancel for the active turn of
  this attempt. Reads the active turn's awakeable id from workflow
  state and completes it with a cancel sentinel; the workflow's
  `Awaitable.any` race wakes on the cancel branch and unwinds.

  Returns `%{"ok" => true}` if a cancel was dispatched, or
  `%{"ok" => false, "reason" => ...}` if no active turn was
  cancellable.
  """
  def cancel(%Context{} = ctx, _input) do
    case Context.get_state(ctx, "current_cancel_awakeable_id") do
      id when is_binary(id) and id != "" ->
        Context.complete_awakeable(ctx, id, "cancelled_by_operator")
        %{"ok" => true, "workflow_key" => Context.key(ctx)}

      _ ->
        %{
          "ok" => false,
          "reason" => "no_active_turn",
          "workflow_key" => Context.key(ctx)
        }
    end
  end

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
    stall_timeout_ms = stall_timeout_from_config(workflow_config)

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
            turn_n: turn_n,
            stall_timeout_ms: stall_timeout_ms
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
      turn_n: turn_n,
      stall_timeout_ms: stall_timeout_ms
    } = ctx_args

    attempt_label = if turn_n == 1, do: nil, else: turn_n

    nudges = drain_pending_nudges(ctx)

    prompt =
      Context.run(ctx, fn ->
        case Prompt.render(prompt_template, %{issue: acc["issue"], attempt: attempt_label}) do
          {:ok, p} -> prepend_operator_nudges(p, nudges)
          {:error, reason} -> terminal!("prompt_render_failed", reason)
        end
      end)

    case run_turn_with_races(
           ctx,
           identifier,
           workspace_path,
           prompt,
           acc["conversation"],
           acc["issue"],
           codex_opts,
           stall_timeout_ms
         ) do
      {:redirect, _reason} ->
        # nudge_now aborted this turn; the operator's text is
        # already staged in `nudge:*` state for the next turn's
        # drain. Don't append a turn record and don't post a
        # Linear comment for the abandoned turn. Continue the
        # loop unless we've hit max_turns.
        cond do
          turn_n >= max_turns ->
            {:halt,
             %{
               "ok" => true,
               "identifier" => identifier,
               "attempt_n" => attempt_n,
               "issue_id" => acc["issue"]["id"],
               "turns" => turn_n,
               "ended_by" => "max_turns_via_nudge_now"
             }}

          true ->
            refreshed = fetch_issue(ctx, identifier)
            {:cont, %{"issue" => refreshed, "conversation" => acc["conversation"]}}
        end

      response when is_binary(response) ->
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
  end

  # Four-way race: codex turn vs stall timer vs operator cancel vs
  # operator nudge_now. Cancel and nudge_now both publish awakeable
  # ids to workflow state so shared handlers can complete them from
  # outside the running workflow.
  #
  # Returns:
  #   * `text :: String.t()` — turn completed normally.
  #   * `{:redirect, reason}` — nudge_now fired; turn abandoned, the
  #     operator's text is already staged in `nudge:*` state, the
  #     caller continues the loop without recording a turn.
  #
  # Raises terminal:
  #   * stall   → `codex_turn_stall`
  #   * cancel  → `cancelled_by_operator`
  #
  # Restate's CANCEL signal can't preempt code already executing
  # inside `ctx.run` (the model's tool-call loop runs to its own
  # completion). The port-kill is the OTP-side preemption that
  # meets the operator's intent halfway: Session's
  # `handle_info({port, {:exit_status, _}}, ...)` stops the
  # GenServer, the in-flight `Manager.run_turn` returns
  # `{:error, {:port_exit, _}}`, and the abandoned `CodexTurnService`
  # invocation terminates on its own.
  defp run_turn_with_races(
         ctx,
         identifier,
         workspace_path,
         prompt,
         conversation,
         issue,
         codex_opts,
         stall_timeout_ms
       ) do
    payload = %{
      "identifier" => identifier,
      "workspace_path" => workspace_path,
      "prompt" => prompt,
      "conversation_so_far" => conversation,
      "issue_meta" => %{
        "identifier" => issue["identifier"],
        "title" => issue["title"] || ""
      },
      "codex_opts" => keyword_to_string_map(codex_opts)
    }

    {cancel_id, cancel_handle} = Context.awakeable(ctx)
    {nudge_now_id, nudge_now_handle} = Context.awakeable(ctx)
    Context.set_state(ctx, "current_cancel_awakeable_id", cancel_id)
    Context.set_state(ctx, "current_nudge_now_awakeable_id", nudge_now_id)

    turn_handle = Context.call_async(ctx, @codex_turn_service, @codex_turn_handler, payload)
    stall_handle = Context.timer(ctx, stall_timeout_ms)

    case Awaitable.any(ctx, [turn_handle, stall_handle, cancel_handle, nudge_now_handle]) do
      {0, %{"text" => text}} when is_binary(text) and text != "" ->
        text

      {0, %{"text" => ""}} ->
        "[symphony-restate] codex turn completed without an extractable agent message; check the Restate journal for raw events."

      {0, other} ->
        terminal!("codex_turn_invalid_response", other)

      {1, :ok} ->
        # Stall fired. Kill the port so the abandoned in-flight turn
        # releases its file descriptors instead of running to its
        # own (long) timeout.
        Context.run(ctx, fn ->
          Manager.stop_session(identifier)
          :ok
        end)

        terminal!("codex_turn_stall", %{stall_timeout_ms: stall_timeout_ms})

      {2, _value} ->
        # Operator cancel fired via `cancel/2`. Kill the port to
        # break the in-flight `ctx.run` halfway and let resources
        # release; raise terminal so `IssueVO.dispatch` records a
        # cancel-typed claim status.
        Context.run(ctx, fn ->
          Manager.stop_session(identifier)
          :ok
        end)

        terminal!("cancelled_by_operator", %{turn_n: nil})

      {3, _value} ->
        # Operator nudge_now fired via `nudge_now/2`. Kill the port
        # so the abandoned turn's resources release; signal the
        # caller to continue the loop. The operator's text is
        # already staged in `nudge:*` state (the `nudge_now/2`
        # handler wrote it before completing the awakeable) so the
        # next turn's drain picks it up as the next operator
        # interjection.
        Context.run(ctx, fn ->
          Manager.stop_session(identifier)
          :ok
        end)

        {:redirect, "nudge_now"}
    end
  end

  # ---------------------- Helpers ----------------------

  defp terminal!(label, reason) do
    raise Restate.TerminalError,
      code: 500,
      message: "#{label}: #{inspect(reason)}"
  end

  # Read every `nudge:*` state key, decode its payload, and clear
  # the slot. Sorted lexicographically — keys embed a left-padded
  # millisecond timestamp so this yields the operator's chronological
  # send order.
  defp drain_pending_nudges(ctx) do
    ctx
    |> Context.state_keys()
    |> Enum.filter(&String.starts_with?(&1, @nudge_state_prefix))
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      payload = Context.get_state(ctx, key)
      Context.clear_state(ctx, key)

      case payload do
        %{"text" => text} = nudge when is_binary(text) and text != "" -> [nudge]
        _ -> []
      end
    end)
  end

  defp prepend_operator_nudges(prompt, []), do: prompt

  defp prepend_operator_nudges(prompt, nudges) do
    block =
      Enum.map_join(nudges, "\n\n", fn n ->
        ts = format_nudge_at(n["received_at_ms"])
        "### Operator interjection (received #{ts}):\n#{n["text"]}"
      end)

    block <> "\n\n---\n\n" <> prompt
  end

  defp format_nudge_at(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_nudge_at(_), do: "unknown time"

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

  defp stall_timeout_from_config(config) do
    case get_in(config, ["codex", "stall_timeout_ms"]) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_stall_timeout_ms
    end
  end

  # CodexTurnService input is JSON-decoded as an object, so codex_opts
  # must travel as a string-keyed map (not a Keyword list).
  defp keyword_to_string_map(opts) when is_list(opts) do
    Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp keyword_to_string_map(_), do: %{}

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
