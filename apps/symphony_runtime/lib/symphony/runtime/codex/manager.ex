defmodule Symphony.Runtime.Codex.Manager do
  @moduledoc """
  Public API for `IssueVO` to drive codex turns through pinned
  long-lived `Codex.Session` GenServers.

  Per-issue session affinity: looks up an existing Session for the
  issue identifier in `Symphony.Runtime.Codex.Registry`; spawns one
  via `Symphony.Runtime.Codex.Supervisor` if absent. The Session
  outlives any single Restate invocation so subsequent turns reuse
  the warm port + codex thread.

  When the BEAM node dies, all Sessions die with it. Restate routes
  the next `IssueVO` invocation to a different node; this Manager
  on that node spawns a fresh Session; the Session's cold-path
  seeding logic re-builds codex context from `IssueVO`'s durable
  conversation state.
  """

  alias Symphony.Runtime.Codex.{IssueSupervisor, Session, Supervisor, Registry}

  @type turn_record :: Session.turn_record()

  @doc """
  Run one turn for the given issue. Spawns the Session if it doesn't
  yet exist on this node.

  Tolerates a single race against a Session that just died (idle
  timeout, port exit, or supervisor decision): if the call exits
  with `:noproc` or `:normal`, force a respawn and retry once.
  """
  @spec run_turn(
          identifier :: String.t(),
          workspace :: Path.t(),
          prompt :: String.t(),
          conversation_so_far :: [turn_record()],
          issue_meta :: map(),
          opts :: keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def run_turn(identifier, workspace, prompt, conversation_so_far, issue_meta, opts \\ []) do
    do_run_turn(identifier, workspace, prompt, conversation_so_far, issue_meta, opts, _retried? = false)
  end

  defp do_run_turn(identifier, workspace, prompt, conversation_so_far, issue_meta, opts, retried?) do
    payload = %{
      prompt: prompt,
      conversation_so_far: conversation_so_far,
      issue_meta: issue_meta,
      app_server_opts: opts,
      turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms)
    }

    with {:ok, server} <- ensure_session(identifier, workspace, opts) do
      try do
        Session.run_turn(server, payload)
      catch
        :exit, {reason, _mfa} when reason in [:noproc, :normal] and not retried? ->
          do_run_turn(identifier, workspace, prompt, conversation_so_far, issue_meta, opts, true)
      end
    end
  end

  @doc "Stop the Session for this issue (call after terminal state)."
  @spec stop_session(String.t()) :: :ok
  def stop_session(identifier) do
    case Elixir.Registry.lookup(Registry, identifier) do
      [{pid, _}] -> Session.stop(pid)
      [] -> :ok
    end
  end

  defp ensure_session(identifier, workspace, opts) do
    case Elixir.Registry.lookup(Registry, identifier) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {IssueSupervisor,
                [identifier: identifier, workspace: workspace, app_server_opts: opts]}

        case Elixir.DynamicSupervisor.start_child(Supervisor, spec) do
          {:ok, _sup_pid} ->
            lookup_session_pid(identifier)

          {:error, {:already_started, _sup_pid}} ->
            # Race between two callers; the other one already spawned
            # the pair. The Session under it is registered with the
            # same identifier key, so the lookup wins regardless.
            lookup_session_pid(identifier)

          {:error, _} = err ->
            err
        end
    end
  end

  defp lookup_session_pid(identifier) do
    case Elixir.Registry.lookup(Registry, identifier) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :session_not_registered}
    end
  end
end
