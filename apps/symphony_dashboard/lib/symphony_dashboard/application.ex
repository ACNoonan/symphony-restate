defmodule Symphony.Dashboard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Symphony.Dashboard.PubSub},
      Symphony.Dashboard.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Symphony.Dashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Symphony.Dashboard.Endpoint.config_change(changed, removed)
    :ok
  end
end
