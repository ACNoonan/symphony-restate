defmodule Symphony.Runtime.Linear do
  @moduledoc """
  Minimal Linear GraphQL client for slice 1.

  Two operations:

    * `fetch_issue!/1` — single issue by identifier (e.g. `"SYM-1"`).
    * `post_comment!/2` — post a markdown comment to an issue ID.

  Both raise on error; callers wrap them in `Restate.Context.run/2` so
  failures journal as terminal-or-retryable per the SDK's
  `ctx.run` semantics. The Linear API itself is a `ctx.run`-side
  side effect.

  Reads `LINEAR_API_KEY` from the environment at call time. Endpoint
  override via the `:symphony_runtime, :linear_endpoint` app env
  (default `https://api.linear.app/graphql`).
  """

  alias Symphony.Core.Issue

  @default_endpoint "https://api.linear.app/graphql"

  @issue_query """
  query SymphonyFetchIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state { name }
      branchName
      url
      labels { nodes { name } }
      inverseRelations(first: 50) {
        nodes {
          type
          issue { id identifier state { name } }
        }
      }
      createdAt
      updatedAt
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id }
    }
  }
  """

  @doc "Look up one issue by identifier (e.g. `\"SYM-1\"`). Raises on failure."
  @spec fetch_issue!(String.t()) :: Issue.t()
  def fetch_issue!(identifier) when is_binary(identifier) do
    case graphql!(@issue_query, %{"id" => identifier}) do
      %{"data" => %{"issue" => nil}} ->
        raise "linear_issue_not_found: #{identifier}"

      %{"data" => %{"issue" => node}} ->
        Issue.from_graphql(node)
    end
  end

  @doc "Post a markdown comment to an issue ID. Returns the new comment ID. Raises on failure."
  @spec post_comment!(String.t(), String.t()) :: String.t()
  def post_comment!(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case graphql!(@create_comment_mutation, %{"issueId" => issue_id, "body" => body}) do
      %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => id}}}} ->
        id

      other ->
        raise "linear_comment_create_failed: #{inspect(other)}"
    end
  end

  defp graphql!(query, variables) do
    api_key =
      System.get_env("LINEAR_API_KEY") ||
        raise "LINEAR_API_KEY env var is unset"

    endpoint = Application.get_env(:symphony_runtime, :linear_endpoint, @default_endpoint)

    Req.post!(endpoint,
      headers: [
        {"authorization", api_key},
        {"content-type", "application/json"}
      ],
      json: %{"query" => query, "variables" => variables}
    ).body
    |> tap(&raise_on_errors!/1)
  end

  defp raise_on_errors!(%{"errors" => [_ | _] = errors}), do: raise("linear_graphql_error: #{inspect(errors)}")
  defp raise_on_errors!(_), do: :ok
end
