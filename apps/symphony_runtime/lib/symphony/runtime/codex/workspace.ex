defmodule Symphony.Runtime.Codex.Workspace do
  @moduledoc """
  Per-issue workspace directory management. Slice 1.5 minimum:
  ensure the directory exists. The full `SPEC.md` §3.1.5 hook
  lifecycle (`after_create` / `before_run` / `after_run` /
  `before_remove`) lands in slice 2.
  """

  alias Symphony.Core.Issue

  @doc """
  Ensure a workspace directory exists for the given issue and return
  its absolute path. Idempotent across replays — `File.mkdir_p!/1` is
  a no-op if the directory already exists.
  """
  @spec ensure!(Issue.t(), Path.t()) :: Path.t()
  def ensure!(%Issue{} = issue, root) when is_binary(root) do
    expanded_root = root |> Path.expand() |> Path.absname()
    workspace = Path.join(expanded_root, Issue.workspace_key(issue))
    File.mkdir_p!(workspace)
    workspace
  end
end
