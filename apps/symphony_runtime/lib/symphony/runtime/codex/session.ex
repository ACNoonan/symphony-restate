defmodule Symphony.Runtime.Codex.Session do
  @moduledoc """
  Long-lived codex `app-server` session, one per active issue.

  The OTP half of the BEAM/Restate co-star design: keeps the port +
  codex thread warm across turns within one BEAM node, while
  `IssueVO` durably tracks the conversation in Restate state so a
  fresh Session post-failover can catch up.

  ## Cold-path conversation seeding

  When the IssueVO calls `run_turn/3` after a node failover, the new
  Session has `completed_turns: 0` but the IssueVO's `conversation`
  has prior turns. The Session prepends a "Prior conversation"
  preamble to the next prompt so codex re-builds context in one
  extra round-trip — no separate seed turn, no wasted assistant
  reply. After that the session is hot and subsequent calls send
  bare prompts.

  ## Lifecycle

    * `init/1` — opens the port and runs the handshake. Failure
      causes the GenServer to start with `{:error, reason}`,
      surfaced through the supervisor as a normal start failure.
    * `handle_call({:run_turn, ...})` — drives one `turn/start`
      cycle, with cold-path seeding if the conversation has more
      turns than we've completed locally.
    * `handle_info({port, {:exit_status, _}})` — codex exited; the
      Session stops itself. The DynamicSupervisor leaves it dead;
      the next `Manager.run_turn/5` spawns a fresh one.
  """

  use GenServer, restart: :transient

  require Logger

  alias Symphony.Runtime.Codex.AppServer

  @type turn_record :: %{turn: pos_integer(), prompt: String.t(), response: String.t()}

  # ---------------------- Public API ----------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Build the `:via` tuple used to register a Session by issue identifier."
  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(identifier) when is_binary(identifier) do
    {:via, Elixir.Registry, {Symphony.Runtime.Codex.Registry, identifier}}
  end

  @doc """
  Send one turn through this session.

    * `prompt` — the rendered turn prompt.
    * `conversation_so_far` — the durable conversation list from
      `IssueVO` state. Used to detect cold sessions and prepend a
      preamble.
    * `issue_meta` — `%{identifier:, title:}` used in `turn/start`'s
      `title` field.
  """
  @spec run_turn(GenServer.server(), %{
          prompt: String.t(),
          conversation_so_far: [turn_record()],
          issue_meta: map()
        }) :: {:ok, String.t()} | {:error, term()}
  def run_turn(server, %{prompt: _, conversation_so_far: _, issue_meta: _} = payload) do
    timeout = call_timeout(payload)
    GenServer.call(server, {:run_turn, payload}, timeout)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal, 5_000)

  defp call_timeout(%{turn_timeout_ms: t}) when is_integer(t), do: t + 5_000
  defp call_timeout(_), do: 3_605_000

  # ---------------------- GenServer ----------------------

  @impl true
  def init(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    app_server_opts = Keyword.get(opts, :app_server_opts, [])

    case AppServer.start(workspace, app_server_opts) do
      {:ok, session} ->
        Logger.info(fn -> "codex session opened thread_id=#{session.thread_id}" end)
        Process.flag(:trap_exit, true)
        {:ok, %{session: session, completed_turns: 0, app_server_opts: app_server_opts}}

      {:error, reason} ->
        Logger.error(fn -> "codex session start failed: #{inspect(reason)}" end)
        {:stop, {:codex_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:run_turn,
         %{
           prompt: prompt,
           conversation_so_far: conversation_so_far,
           issue_meta: issue_meta
         } = payload},
        _from,
        state
      ) do
    expected_completed = length(conversation_so_far)

    effective_prompt =
      if expected_completed > state.completed_turns do
        # Cold path: this Session is fresh (or stale post-failover);
        # IssueVO has more conversation than we've replayed. Prepend
        # all missing turns as a preamble; codex catches up in one
        # turn/start cycle.
        missing = Enum.drop(conversation_so_far, state.completed_turns)
        format_with_preamble(missing, prompt)
      else
        prompt
      end

    turn_opts = Map.get(payload, :app_server_opts, []) ++ state.app_server_opts

    case AppServer.turn(state.session, effective_prompt, issue_meta, turn_opts) do
      {:ok, %{text: text}} ->
        # `expected_completed + 1` covers cold-path seeding + the new
        # turn in a single AppServer.turn call.
        new_state = %{state | completed_turns: expected_completed + 1}
        {:reply, {:ok, text}, new_state}

      {:error, reason} = err ->
        # Port is likely toast; stop so the supervisor doesn't keep a
        # half-broken session around. Manager.run_turn re-spawns on
        # the next request.
        Logger.warning(fn -> "codex turn failed: #{inspect(reason)} — stopping session" end)
        {:stop, {:turn_failed, reason}, err, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{session: %{port: port}} = state) do
    Logger.warning(fn -> "codex port exited status=#{status} — stopping session" end)
    {:stop, {:codex_port_exit, status}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{session: session}) do
    AppServer.stop(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------- Helpers ----------------------

  defp format_with_preamble([], prompt), do: prompt

  defp format_with_preamble(missing_turns, prompt) do
    history =
      missing_turns
      |> Enum.map_join("\n\n", fn %{turn: n, prompt: p, response: r} ->
        "### Prior turn #{n} — operator input:\n#{p}\n\n### Prior turn #{n} — your response:\n#{r}"
      end)

    """
    [Continuing a prior conversation. The codex thread you'd normally
    inherit is unavailable because this run resumed on a different
    BEAM node. The conversation transcript follows; treat it as the
    state of your prior reasoning, then act on the new turn input
    below.]

    #{history}

    ---

    Now respond to this turn:

    #{prompt}
    """
    |> String.trim()
  end
end
