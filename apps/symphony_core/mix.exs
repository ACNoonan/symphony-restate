defmodule Symphony.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_core,
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
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:jason, "~> 1.4"}
    ]
  end
end
