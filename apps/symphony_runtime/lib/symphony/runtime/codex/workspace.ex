defmodule Symphony.Runtime.Codex.Workspace do
  @moduledoc """
  Per-issue workspace directory management.

  The path is deterministic in `(root, issue)`, so it is safe to
  journal: `path_for/2` runs inside `ctx.run`. The directory itself
  is node-local and must exist on whichever BEAM node currently
  holds the invocation, so `preflight_local!/1` runs *outside*
  `ctx.run` on every execution (including replays after failover).

  Splitting the two prevents the slice-2 trap: `ensure!/2` inside
  `ctx.run` recorded the path on Node A; on retry to Node B,
  replay returned the journaled path without re-executing the
  `mkdir_p`, so codex saw a missing cwd.
  """

  alias Symphony.Core.Issue

  @doc """
  Compute the absolute workspace path for `(issue, root)`. Pure
  function — safe inside `ctx.run` because journaling the result
  has no node-local side effect.
  """
  @spec path_for(Issue.t(), Path.t()) :: Path.t()
  def path_for(%Issue{} = issue, root) when is_binary(root) do
    expanded_root = root |> Path.expand() |> Path.absname()
    Path.join(expanded_root, Issue.workspace_key(issue))
  end

  @doc """
  Ensure the workspace directory exists on *this* BEAM node.
  Idempotent — `mkdir_p!` is a no-op if the path already exists.
  Call this every time after replaying a journaled workspace path,
  not inside `ctx.run`.
  """
  @spec preflight_local!(Path.t()) :: Path.t()
  def preflight_local!(path) when is_binary(path) do
    File.mkdir_p!(path)
    path
  end

  @doc "Backwards-compatible shortcut: compute path and preflight in one shot."
  @spec ensure!(Issue.t(), Path.t()) :: Path.t()
  def ensure!(%Issue{} = issue, root) when is_binary(root) do
    issue |> path_for(root) |> preflight_local!()
  end
end
