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
      {Phoenix.PubSub, name: Symphony.Runtime.PubSub},
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
        },
        %{
          name: "readState",
          type: :shared,
          mfa: {Symphony.Runtime.IssueVO, :read_state, 2}
        },
        %{
          name: "cancel",
          type: :shared,
          mfa: {Symphony.Runtime.IssueVO, :cancel, 2}
        },
        %{
          name: "nudge",
          type: :shared,
          mfa: {Symphony.Runtime.IssueVO, :nudge, 2}
        },
        %{
          name: "nudgeNow",
          type: :shared,
          mfa: {Symphony.Runtime.IssueVO, :nudge_now, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "RunAttemptWorkflow",
      type: :workflow,
      handlers: [
        %{
          name: "run",
          type: :workflow,
          mfa: {Symphony.Runtime.RunAttemptWorkflow, :run, 2}
        },
        %{
          name: "readState",
          type: :shared,
          mfa: {Symphony.Runtime.RunAttemptWorkflow, :read_state, 2}
        },
        %{
          name: "cancel",
          type: :shared,
          mfa: {Symphony.Runtime.RunAttemptWorkflow, :cancel, 2}
        },
        %{
          name: "nudge",
          type: :shared,
          mfa: {Symphony.Runtime.RunAttemptWorkflow, :nudge, 2}
        },
        %{
          name: "nudgeNow",
          type: :shared,
          mfa: {Symphony.Runtime.RunAttemptWorkflow, :nudge_now, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "CodexTurnService",
      type: :service,
      handlers: [
        %{
          name: "run",
          type: nil,
          mfa: {Symphony.Runtime.CodexTurnService, :run, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "SchedulerVO",
      type: :virtual_object,
      handlers: [
        %{
          name: "start",
          type: :exclusive,
          mfa: {Symphony.Runtime.SchedulerVO, :start, 2}
        },
        %{
          name: "stop",
          type: :exclusive,
          mfa: {Symphony.Runtime.SchedulerVO, :stop, 2}
        },
        %{
          name: "tick",
          type: :exclusive,
          mfa: {Symphony.Runtime.SchedulerVO, :tick, 2}
        },
        %{
          name: "reconcile",
          type: :shared,
          mfa: {Symphony.Runtime.SchedulerVO, :reconcile, 2}
        }
      ]
    })
  end
end
