defmodule Symphony.Runtime.Codex.Watchdog do
  @moduledoc """
  Per-issue observer GenServer paired with `Codex.Session` under
  `Codex.IssueSupervisor`'s `:one_for_all` strategy. Subscribes to the
  same `"agent:\#{identifier}"` topic LiveView consumes, observing the
  stream from inside OTP.

  ## Phase A responsibilities

    * Subscribe to the per-issue PubSub topic so events flow through
      a process the IssueSupervisor can supervise (justifies the
      `:one_for_all` shape — when Session dies, this dies, and the
      supervisor terminates as a clean pair).
    * Track `last_activity_at` and the current `turn_id` (extracted
      from `turn/started`-style events) for diagnostic snapshots.
    * Hold the OTP-side latch for cancellation: when the workflow
      kills the Session via `Manager.stop_session/1`, the Session
      exits, this Watchdog dies with it, and the supervisor unwinds.

  ## Future phases

    * Phase D will use this process as the inbox for mid-turn
      operator nudges that arrive while the current turn is in
      flight; the Watchdog stages them so the next Session pickup
      sees them.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry Symphony.Runtime.Codex.Registry
  @pubsub Symphony.Runtime.PubSub

  # ---------------------- Public API ----------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    GenServer.start_link(__MODULE__, opts, name: via(identifier))
  end

  @spec via(String.t()) :: {:via, module(), {module(), {:watchdog, String.t()}}}
  def via(identifier) when is_binary(identifier) do
    {:via, Elixir.Registry, {@registry, {:watchdog, identifier}}}
  end

  @doc "Diagnostic snapshot — useful for debugging and future stall heuristics."
  @spec snapshot(String.t()) :: {:ok, map()} | {:error, :no_watchdog}
  def snapshot(identifier) when is_binary(identifier) do
    case Elixir.Registry.lookup(@registry, {:watchdog, identifier}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :snapshot)}
      [] -> {:error, :no_watchdog}
    end
  end

  # ---------------------- GenServer ----------------------

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    topic = "agent:" <> identifier

    case Phoenix.PubSub.subscribe(@pubsub, topic) do
      :ok -> :ok
      {:error, reason} -> Logger.warning(fn -> "watchdog pubsub subscribe failed: #{inspect(reason)}" end)
    end

    {:ok,
     %{
       identifier: identifier,
       topic: topic,
       last_activity_at: nil,
       last_method: nil,
       turn_id: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:identifier, :last_activity_at, :last_method, :turn_id]), state}
  end

  @impl true
  def handle_info({:agent_event, identifier, payload}, %{identifier: identifier} = state) do
    {:noreply,
     %{
       state
       | last_activity_at: System.system_time(:millisecond),
         last_method: Map.get(payload, "method"),
         turn_id: maybe_turn_id(payload, state.turn_id)
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_turn_id(%{"method" => "turn/started", "params" => %{"turn" => %{"id" => id}}}, _prev),
    do: id

  defp maybe_turn_id(%{"method" => "turn/" <> _}, prev), do: prev
  defp maybe_turn_id(_, prev), do: prev
end
