defmodule Symphony.Core.Issue do
  @moduledoc """
  Normalized Linear issue. Mirrors `SPEC.md` §4.1.1 — the shape every
  Restate handler and prompt template renders against.

  Pure: no Linear API calls live here. `Symphony.Runtime.Linear` is
  responsible for the GraphQL fetch and hands a raw payload to
  `from_graphql/1` for normalization.
  """

  @type blocker :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          state: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [blocker()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    labels: [],
    blocked_by: [],
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Build an `Issue` from a Linear GraphQL `issue { ... }` payload.
  Labels are normalized to lowercase per `SPEC.md` §4.2.
  """
  @spec from_graphql(map()) :: t()
  def from_graphql(%{} = node) do
    %__MODULE__{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      description: node["description"],
      priority: node["priority"],
      state: get_in(node, ["state", "name"]),
      branch_name: node["branchName"],
      url: node["url"],
      labels:
        node
        |> get_in(["labels", "nodes"])
        |> List.wrap()
        |> Enum.map(fn %{"name" => n} -> String.downcase(n) end),
      blocked_by:
        node
        |> get_in(["inverseRelations", "nodes"])
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "blocks"))
        |> Enum.map(fn rel ->
          %{
            id: get_in(rel, ["issue", "id"]),
            identifier: get_in(rel, ["issue", "identifier"]),
            state: get_in(rel, ["issue", "state", "name"])
          }
        end),
      created_at: node["createdAt"],
      updated_at: node["updatedAt"]
    }
  end

  @doc """
  `SPEC.md` §4.2 workspace-key derivation: replace any character not in
  `[A-Za-z0-9._-]` with `_`. Used for the per-issue workspace directory
  name and for the Restate VO key.
  """
  @spec workspace_key(t() | String.t()) :: String.t()
  def workspace_key(%__MODULE__{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    String.replace(identifier, ~r/[^A-Za-z0-9._-]/, "_")
  end
end
