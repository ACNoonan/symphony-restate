defmodule Symphony.Dashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_dashboard,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Symphony.Dashboard.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:symphony_core, in_umbrella: true}
    ]
  end
end
