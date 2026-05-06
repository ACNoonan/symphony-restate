defmodule Symphony.Runtime.Codex.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-issue `Codex.Session` GenServers.
  Strategy `:one_for_one`; sessions that die do not auto-restart —
  the next `Manager.run_turn/6` call spawns a fresh one with cold-path
  seeding from the durable conversation in `IssueVO` state.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
