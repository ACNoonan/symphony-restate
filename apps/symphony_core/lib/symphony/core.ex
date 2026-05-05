defmodule Symphony.Core do
  @moduledoc """
  Pure domain layer for Symphony-on-Restate.

  No Restate calls, no IO, no GenServers. WORKFLOW.md parsing,
  prompt rendering, issue/run-attempt structs, normalization rules
  per `SPEC.md` §4. Everything in this app is replay-safe by
  construction so it can be called from inside `ctx.run` blocks
  in `:symphony_runtime`.
  """
end
