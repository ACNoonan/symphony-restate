import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:issue_id, :issue_identifier, :worker_node]

config :restate_server, port: 9082

config :symphony_runtime,
  workspace_root: System.tmp_dir!() |> Path.join("symphony_workspaces"),
  workflow_path: Path.expand("../WORKFLOW.md", __DIR__),
  linear_endpoint: "https://api.linear.app/graphql"

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
