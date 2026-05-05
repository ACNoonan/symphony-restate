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

  defp deps, do: []
end
