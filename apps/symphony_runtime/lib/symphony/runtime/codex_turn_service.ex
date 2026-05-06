defmodule Symphony.Runtime.CodexTurnService do
  @moduledoc """
  Restate Service that wraps one `Codex.Manager.run_turn/6` call.

  ## Why a Restate service, not a local function

  Slice 2.5 ran the codex turn inside the workflow's own
  `ctx.run` block. That worked but had no awaitable boundary —
  the workflow could not race the turn against a stall timer
  without turning the whole call inside out.

  Slice 3 promotes the turn to its own service so the workflow
  can:

    * `ctx.call_async` it and get an awaitable handle
    * `Awaitable.any/2` it against `ctx.timer/2` for stall
      detection (`SPEC.md` §8.5)
    * `cancel_invocation` it via Restate's CANCEL signal — the
      cascade reaches this service's next suspending op (the
      next `ctx.run`'s flush, or the implicit final
      `OutputCommandMessage` write)

  The actual port I/O is still local to whichever BEAM node
  Restate routes this invocation to. `Codex.Manager` finds-or-
  spawns the per-issue `Codex.Session` on that node; cold-path
  conversation seeding rebuilds context if it's a fresh session.

  ## Cancellation reach

  Restate's CANCEL signal raises `TerminalError{code: 409,
  message: "cancelled"}` from the *next* suspending Context op —
  it cannot preempt code already executing inside `ctx.run`.
  In practice this means:

    * Cancel between turns (between `ctx.run`s): clean.
    * Cancel during the codex turn itself: the `ctx.run` runs
      to completion (the codex port keeps streaming), then the
      cancel raises on the next suspending op.

  For a hard preempt during a turn — the chaos beat where a
  stall-fire actually stops the agent mid-thought — the
  workflow additionally calls `Codex.Manager.stop_session/1`
  to kill the port. The `ctx.run` then returns the port-exit
  error, the workflow records the failure, and the durable
  state is consistent.

  ## Input / output

  Input (from `RunAttemptWorkflow`):

      %{
        "identifier" => "SYM-1",
        "workspace_path" => "/abs/.../SYM-1",
        "prompt" => "...",
        "conversation_so_far" => [%{"turn", "prompt", "response"}, ...],
        "issue_meta" => %{"identifier", "title"},
        "codex_opts" => [{"turn_timeout_ms", 3_600_000}, ...]   # JSON: object
      }

  Output:

      %{"text" => "...agent message..."}
  """

  require Logger

  alias Restate.Context
  alias Symphony.Runtime.Codex.Manager

  @doc "Restate handler. Drives one codex turn."
  def run(%Context{} = ctx, input) when is_map(input) do
    identifier = require_string!(input, "identifier")
    workspace_path = require_string!(input, "workspace_path")
    prompt = require_string!(input, "prompt")
    conversation_so_far = Map.get(input, "conversation_so_far", [])
    issue_meta_in = Map.get(input, "issue_meta", %{})
    codex_opts_in = Map.get(input, "codex_opts", %{})

    Logger.metadata(issue_identifier: identifier)

    Context.run(ctx, fn ->
      issue_meta = atomize_issue_meta(issue_meta_in)
      codex_opts = decode_codex_opts(codex_opts_in)

      conversation_for_session =
        Enum.map(conversation_so_far, fn rec ->
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
          %{
            "text" =>
              "[symphony-restate] codex turn completed without an extractable agent message; check the Restate journal for raw events."
          }

        {:ok, text} ->
          %{"text" => text}

        {:error, reason} ->
          terminal!("codex_turn_failed", reason)
      end
    end)
  end

  # ---------------------- Helpers ----------------------

  defp terminal!(label, reason) do
    raise Restate.TerminalError,
      code: 500,
      message: "#{label}: #{inspect(reason)}"
  end

  defp require_string!(input, key) do
    case Map.get(input, key) do
      v when is_binary(v) -> v
      other -> terminal!("invalid_codex_turn_input", {key, other})
    end
  end

  # `issue_meta` flows in as a JSON-decoded map (string keys); the
  # AppServer's `turn/start` builds `title` from the identifier and
  # title fields, accepting both atom- and string-keyed input.
  defp atomize_issue_meta(meta) when is_map(meta) do
    %{
      identifier: meta["identifier"] || meta[:identifier],
      title: meta["title"] || meta[:title] || ""
    }
  end

  # `codex_opts` flows in as a JSON-decoded *object* (string keys),
  # but `AppServer.turn/4` and `Manager.run_turn/6` expect a Keyword
  # list with atom keys. Convert known keys here; ignore unknowns.
  @known_codex_opts ~w(codex_command approval_policy thread_sandbox turn_sandbox_policy turn_timeout_ms read_timeout_ms idle_timeout_ms)a
  defp decode_codex_opts(opts) when is_map(opts) do
    Enum.flat_map(@known_codex_opts, fn key ->
      case Map.get(opts, Atom.to_string(key)) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  defp decode_codex_opts(_), do: []
end
