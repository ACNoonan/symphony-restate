defmodule Mix.Tasks.Symphony.Chaos do
  @shortdoc "Trigger a slice 5 chaos beat (kill_codex / kill_beam / kill_restate)"

  @moduledoc """
  Slice 5: thin wrapper around the shell scripts in
  `scripts/chaos/`. Lets the demo operator trigger beats from the
  same terminal that's running `mix symphony.scheduler` etc.,
  without remembering shell paths.

  ## Usage

      mix symphony.chaos kill_codex
      mix symphony.chaos kill_beam        # this WILL kill the BEAM you're typing into
      mix symphony.chaos kill_restate

  Each beat is documented in `docs/demo-script.md`. The scripts
  print a banner of what they do and what to expect on the
  dashboard.

  ## Note on `kill_beam`

  Because `mix` itself runs inside the BEAM you're about to kill,
  `mix symphony.chaos kill_beam` from the same terminal that owns
  the BEAM is self-cancelling. Run it from a *different* shell —
  or just call `./scripts/chaos/kill-beam.sh` directly.
  """

  use Mix.Task

  @beats %{
    "kill_codex" => "scripts/chaos/kill-codex.sh",
    "kill_beam" => "scripts/chaos/kill-beam.sh",
    "kill_restate" => "scripts/chaos/kill-restate.sh"
  }

  @impl Mix.Task
  def run(argv) do
    case argv do
      [beat] when is_map_key(@beats, beat) ->
        script = Map.fetch!(@beats, beat)
        path = Path.expand(script, umbrella_root())

        unless File.exists?(path) do
          Mix.raise("chaos script not found: #{path}")
        end

        Mix.shell().info("→ #{path}\n")

        case System.cmd("bash", [path], into: IO.stream(:stdio, :line)) do
          {_, 0} -> :ok
          {_, code} -> Mix.raise("chaos beat '#{beat}' exited with code #{code}")
        end

      _ ->
        Mix.raise("""
        usage: mix symphony.chaos <beat>

        beats:
          kill_codex    pkill -9 the codex Port child
          kill_beam     pkill -9 the symphony-restate BEAM (run from a different shell!)
          kill_restate  docker kill the Restate container

        See docs/demo-script.md for what each beat demonstrates.
        """)
    end
  end

  defp umbrella_root do
    # Mix.Project.config() runs in the umbrella root context. From
    # `apps/symphony_runtime/`, `..` twice gets us back to the umbrella.
    File.cwd!()
    |> find_umbrella_root()
  end

  defp find_umbrella_root(path) do
    if File.exists?(Path.join(path, "docker-compose.yml")) and
         File.exists?(Path.join(path, "scripts/chaos")) do
      path
    else
      parent = Path.dirname(path)

      if parent == path do
        Mix.raise("could not locate symphony-restate umbrella root from #{File.cwd!()}")
      else
        find_umbrella_root(parent)
      end
    end
  end
end
