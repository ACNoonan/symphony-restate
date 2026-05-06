defmodule Mix.Tasks.Symphony.Scheduler do
  @shortdoc "Start, stop, tick, or reconcile the SchedulerVO poll loop for a project"

  @moduledoc """
  Slice 3: drive the per-project poll loop from the CLI. The
  scheduler is a Restate VO that self-reschedules its tick via
  `ctx.send(invoke_at_ms:)` — once started it runs until `stop`.

  ## Usage

      mix symphony.scheduler start <PROJECT_SLUG> [--interval 30000] [--exec]
      mix symphony.scheduler stop  <PROJECT_SLUG>                   [--exec]
      mix symphony.scheduler tick  <PROJECT_SLUG>                   [--exec]
      mix symphony.scheduler reconcile <PROJECT_SLUG>               [--exec]

  Without `--exec`, prints the curl. With `--exec`, runs it.
  Same shape as `mix symphony.dispatch` (slice 1).

  ## Prereqs

  Same as `mix symphony.dispatch`:

      mix run --no-halt                                       # in another shell
      restate --yes deployments register http://localhost:9082
  """

  use Mix.Task

  @restate_ingress_default "http://localhost:8080"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        switches: [exec: :boolean, ingress: :string, interval: :integer],
        aliases: [e: :exec, i: :ingress]
      )

    {action, project_slug} = parse_args!(args)
    ingress = Keyword.get(opts, :ingress, @restate_ingress_default)

    {url, body} = endpoint_for(action, ingress, project_slug, opts)

    Mix.shell().info("""

    ── slice 3 scheduler · #{action} ────────────────────────────────
    Project slug:    #{project_slug}
    Restate ingress: #{ingress}

    Trigger:

        curl -sS -X POST '#{url}' \\
          -H 'content-type: application/json' \\
          -d '#{body}'

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
             body
           ]) do
        {response, 0} -> Mix.shell().info(response)
        {response, code} -> Mix.raise("curl failed (exit #{code}): #{response}")
      end
    end
  end

  defp parse_args!([action, slug]) when action in ~w(start stop tick reconcile),
    do: {action, slug}

  defp parse_args!(_),
    do:
      Mix.raise(
        "usage: mix symphony.scheduler <start|stop|tick|reconcile> <PROJECT_SLUG> [--interval <ms>] [--exec]"
      )

  defp endpoint_for("start", ingress, project_slug, opts) do
    interval = Keyword.get(opts, :interval, 30_000)

    {
      url(ingress, project_slug, "start"),
      Jason.encode!(%{interval_ms: interval})
    }
  end

  defp endpoint_for(action, ingress, project_slug, _opts)
       when action in ~w(stop tick reconcile) do
    {url(ingress, project_slug, action), "null"}
  end

  defp url(ingress, project_slug, handler) do
    "#{ingress}/SchedulerVO/#{URI.encode_www_form(project_slug)}/#{handler}"
  end
end
