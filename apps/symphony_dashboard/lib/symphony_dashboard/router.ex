defmodule Symphony.Dashboard.Router do
  use Phoenix.Router, helpers: false

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Symphony.Dashboard.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", Symphony.Dashboard do
    pipe_through :browser

    live "/", OverviewLive, :index
  end
end
