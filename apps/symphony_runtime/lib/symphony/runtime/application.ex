defmodule Symphony.Runtime.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    register_services()

    Logger.info(fn ->
      port = Application.get_env(:restate_server, :port, 9080)
      "symphony-restate handlers registered; restate endpoint listening on :#{port}"
    end)

    children = [
      {Registry, keys: :unique, name: Symphony.Runtime.Codex.Registry},
      Symphony.Runtime.Codex.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Symphony.Runtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp register_services do
    Restate.Server.Registry.register_service(%{
      name: "IssueVO",
      type: :virtual_object,
      handlers: [
        %{
          name: "dispatch",
          type: :exclusive,
          mfa: {Symphony.Runtime.IssueVO, :dispatch, 2}
        }
      ]
    })
  end
end
