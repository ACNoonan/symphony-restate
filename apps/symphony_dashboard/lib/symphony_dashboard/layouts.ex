defmodule Symphony.Dashboard.Layouts do
  @moduledoc """
  Root + app layouts for the slice 4 dashboard. HEEx inline so the
  whole dashboard fits in a handful of files — no asset pipeline,
  no separate template files. Pulls the LiveView client JS from
  the Phoenix-hosted CDN-style URL emitted by Endpoint.

  Minimal CSS lives in `root/1` so the demo looks readable in any
  browser without a build step.
  """

  use Phoenix.Component

  @doc "HTML root layout. Wraps every response."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>symphony-restate · dashboard</title>
        <style>
          :root {
            --bg: #0e0e10;
            --panel: #17171b;
            --border: #2a2a31;
            --text: #e6e6ea;
            --muted: #8a8a93;
            --accent: #6ad7ff;
            --warn: #ffae42;
            --bad: #ff6970;
            --ok: #5fd28a;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font: 14px/1.5 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
            background: var(--bg);
            color: var(--text);
          }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          header.app {
            display: flex; align-items: baseline; gap: 1rem;
            padding: 1rem 1.5rem;
            border-bottom: 1px solid var(--border);
          }
          header.app h1 { margin: 0; font-size: 1rem; }
          header.app .muted { color: var(--muted); font-size: 0.85rem; }
          main.app { padding: 1rem 1.5rem; max-width: 1200px; margin: 0 auto; }
          section.panel {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 1rem;
            margin-bottom: 1rem;
          }
          section.panel h2 { margin: 0 0 0.5rem 0; font-size: 0.95rem; }
          .kv { display: grid; grid-template-columns: 12rem 1fr; gap: 0.25rem 1rem; }
          .kv .k { color: var(--muted); }
          .kv .v.code { word-break: break-all; }
          table.issues { width: 100%; border-collapse: collapse; }
          table.issues th, table.issues td {
            text-align: left;
            padding: 0.5rem 0.75rem;
            border-bottom: 1px solid var(--border);
          }
          table.issues th { color: var(--muted); font-weight: 500; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.5px; }
          table.issues tr.row { cursor: pointer; }
          table.issues tr.row:hover { background: rgba(106, 215, 255, 0.06); }
          .badge {
            display: inline-block;
            padding: 0.1rem 0.5rem;
            border-radius: 999px;
            font-size: 0.75rem;
            border: 1px solid var(--border);
          }
          .badge.running { color: var(--accent); border-color: var(--accent); }
          .badge.done    { color: var(--ok);     border-color: var(--ok); }
          .badge.failed  { color: var(--bad);    border-color: var(--bad); }
          .badge.unclaimed { color: var(--muted); }
          details.attempt { margin-top: 0.5rem; }
          details.attempt > summary { cursor: pointer; padding: 0.25rem 0; color: var(--muted); }
          .turn {
            border-left: 2px solid var(--border);
            padding: 0.25rem 0 0.25rem 0.75rem;
            margin: 0.5rem 0;
          }
          .turn .role { color: var(--muted); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; }
          .turn pre { white-space: pre-wrap; word-break: break-word; margin: 0.25rem 0 0 0; font-size: 0.85rem; }
          .footer {
            color: var(--muted);
            font-size: 0.75rem;
            margin-top: 2rem;
            padding-top: 1rem;
            border-top: 1px solid var(--border);
          }
          .stale {
            color: var(--warn);
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script phx-track-static type="text/javascript" src="/assets/phoenix/phoenix.min.js">
        </script>
        <script phx-track-static type="text/javascript" src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script type="text/javascript">
          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, { params: { _csrf_token: csrfToken } });
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end
end
