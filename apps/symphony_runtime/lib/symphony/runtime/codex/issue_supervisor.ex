defmodule Symphony.Runtime.Codex.IssueSupervisor do
  @moduledoc """
  Per-issue mini-supervisor wrapping `Codex.Session` and
  `Codex.Watchdog` under `:one_for_all`.

  ## Why `:one_for_all` with `max_restarts: 0`

  When the Codex port dies, the Session exits; the `:one_for_all`
  strategy takes the Watchdog with it, and `max_restarts: 0` means
  this supervisor terminates instead of looping. The parent
  `Codex.Supervisor` (DynamicSupervisor) sees the temporary child
  exit and removes it. The next `Manager.run_turn/6` call spawns a
  fresh IssueSupervisor pair; the new Session's cold-path seeding
  rebuilds Codex context from the workflow's durable conversation.

  This is the BEAM half of the co-star design: OTP gives Restate a
  clean "all dead" signal instead of trying to be clever about
  restarting the agent. Restate's workflow layer owns retry policy.
  """

  use Supervisor, restart: :temporary

  alias Symphony.Runtime.Codex.{Session, Watchdog}

  @registry Symphony.Runtime.Codex.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    Supervisor.start_link(__MODULE__, opts, name: via(identifier))
  end

  @spec via(String.t()) :: {:via, module(), {module(), {:issue_supervisor, String.t()}}}
  def via(identifier) when is_binary(identifier) do
    {:via, Elixir.Registry, {@registry, {:issue_supervisor, identifier}}}
  end

  @impl true
  def init(opts) do
    identifier = Keyword.fetch!(opts, :identifier)
    workspace = Keyword.fetch!(opts, :workspace)
    app_server_opts = Keyword.get(opts, :app_server_opts, [])

    children = [
      {Watchdog, [identifier: identifier]},
      {Session,
       [
         name: Session.via(identifier),
         identifier: identifier,
         workspace: workspace,
         app_server_opts: app_server_opts
       ]}
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 0,
      max_seconds: 1
    )
  end
end
