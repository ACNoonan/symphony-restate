defmodule SymphonyRestate.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.0.1",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Root deps live here so they are visible to every umbrella app via
  # path-deps. Credo is required at compile time by the path-dep
  # `restate_server`'s `Restate.Credo.Checks.NonDeterminism` module
  # (which `use`s `Credo.Check`); without it, recompiling restate_server
  # fails with `module Credo.Check is not loaded`.
  defp deps, do: [
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
