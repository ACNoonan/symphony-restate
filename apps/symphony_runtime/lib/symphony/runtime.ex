defmodule Symphony.Runtime do
  @moduledoc """
  Restate-facing runtime for Symphony-on-Restate.

  Hosts the Restate handlers (`IssueVO`, `RunAttemptWorkflow`,
  scheduler) and the OTP-supervised side: `Codex.Session`
  GenServers, the Linear client, CLI tasks.

  Co-star architecture: Restate handlers are the durable source
  of truth (claim state, conversation journal, worker-node
  affinity); OTP supervises the long-lived stdio ports inside
  one BEAM node. Failure beats are designed at both layers —
  see `docs/architecture.md`.
  """
end
