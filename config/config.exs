import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:issue_id, :issue_identifier, :worker_node]

config :restate_server, port: 9082

config :symphony_runtime,
  workspace_root: System.tmp_dir!() |> Path.join("symphony_workspaces"),
  workflow_path: Path.expand("../WORKFLOW.md", __DIR__),
  linear_endpoint: "https://api.linear.app/graphql",
  codex_session_idle_timeout_ms: :timer.minutes(5)

config :symphony_dashboard,
  workflow_path: Path.expand("../WORKFLOW.md", __DIR__),
  restate_ingress: "http://localhost:8080",
  refresh_interval_ms: 2_000

config :symphony_dashboard, Symphony.Dashboard.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  adapter: Bandit.PhoenixAdapter,
  # Bind the HTTP server when started via `mix run --no-halt`. Without
  # this, Phoenix.Endpoint starts but never listens — `mix phx.server`
  # is the only other way to flip this on.
  server: true,
  render_errors: [
    formats: [html: Symphony.Dashboard.ErrorHTML],
    layout: false
  ],
  pubsub_server: Symphony.Dashboard.PubSub,
  live_view: [signing_salt: "symphony-restate-live"],
  # Demo-only static secret_key_base. Replace before any production use.
  secret_key_base: "ZDV3eW1KSlpITFlvNGMrM2g0WVlZbjVGTU8wL3VKcWh1d3RDV3pKa1FJUTNSWlpa"

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
