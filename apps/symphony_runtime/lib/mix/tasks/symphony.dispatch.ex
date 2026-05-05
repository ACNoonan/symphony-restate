defmodule Mix.Tasks.Symphony.Dispatch do
  @shortdoc "Manually trigger a single IssueVO.dispatch invocation"

  @moduledoc """
  Slice 1 manual fire: print the registration + curl commands for one
  issue identifier. The poll-loop scheduler (slice 3) will replace this.

  ## Usage

      mix symphony.dispatch SYM-1

  Assumes the BEAM app is running (`iex -S mix` from the umbrella
  root), `restate-server` is up at the standard ports, and the
  endpoint is registered:

      restate deployments register http://localhost:9082

  Then this task just shows you the ingress curl. You can either run
  it yourself or pass `--exec` to have the task `System.cmd` it.
  """

  use Mix.Task

  @restate_ingress_default "http://localhost:8080"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        switches: [exec: :boolean, ingress: :string],
        aliases: [e: :exec, i: :ingress]
      )

    identifier =
      case args do
        [id] -> id
        _ -> Mix.raise("usage: mix symphony.dispatch <ISSUE-IDENTIFIER> [--exec]")
      end

    ingress = Keyword.get(opts, :ingress, @restate_ingress_default)
    url = "#{ingress}/IssueVO/#{URI.encode_www_form(identifier)}/dispatch"

    Mix.shell().info("""

    ── slice 1 manual dispatch ──────────────────────────────────────
    Issue identifier: #{identifier}
    Restate ingress:  #{ingress}

    Make sure the deployment is registered (one-time per run):

        restate --yes deployments register http://localhost:9082

    Trigger:

        curl -sS -X POST '#{url}' \\
          -H 'content-type: application/json' \\
          -d 'null'

    """)

    if Keyword.get(opts, :exec, false) do
      Mix.shell().info("→ executing curl")

      case System.cmd("curl", [
             "-sS",
             "-X",
             "POST",
             url,
             "-H",
             "content-type: application/json",
             "-d",
             "null"
           ]) do
        {body, 0} -> Mix.shell().info(body)
        {body, code} -> Mix.raise("curl failed (exit #{code}): #{body}")
      end
    end
  end
end
