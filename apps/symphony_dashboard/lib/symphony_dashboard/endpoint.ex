defmodule Symphony.Dashboard.Endpoint do
  use Phoenix.Endpoint, otp_app: :symphony_dashboard

  @session_options [
    store: :cookie,
    key: "_symphony_dashboard_key",
    signing_salt: "symphony-dashboard",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve the Phoenix + LiveView JS from each dep's priv/static so the
  # dashboard works without an asset build step. Two static plugs at
  # disjoint prefixes since Plug.Static reads from one directory each.
  plug Plug.Static,
    at: "/assets/phoenix",
    from: :phoenix,
    gzip: false,
    only: ~w(phoenix.min.js phoenix.js)

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: :phoenix_live_view,
    gzip: false,
    only: ~w(phoenix_live_view.min.js phoenix_live_view.js)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Symphony.Dashboard.Router
end
