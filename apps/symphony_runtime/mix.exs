defmodule Symphony.Runtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_runtime,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Symphony.Runtime.Application, []}
    ]
  end

  defp deps do
    [
      {:symphony_core, in_umbrella: true},
      {:restate_server, path: "../../../restate-elixir/apps/restate_server"},
      {:restate_protocol, path: "../../../restate-elixir/apps/restate_protocol"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
