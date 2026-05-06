defmodule Symphony.Runtime.Linear do
  @moduledoc """
  Minimal Linear GraphQL client.

  Operations:

    * `fetch_issue!/1` — single issue by identifier (e.g. `"SYM-1"`).
    * `post_comment!/2` — post a markdown comment to an issue ID.
      Caller-managed idempotency.
    * `post_comment_idempotent!/3` — search-or-create variant: if a
      comment whose body contains the given marker already exists on
      the issue, return that comment's id; otherwise post a new one.
      Used by `RunAttemptWorkflow` so a replayed `ctx.run` after a
      lost response cannot duplicate per-turn comments.
    * `attempt_turn_marker/3` — deterministic marker string built
      from `(identifier, attempt_n, turn_n)`; embedded in the
      comment body as an HTML comment so it's invisible to readers
      but greppable from the API.

  All raise on error; callers wrap them in `Restate.Context.run/2` so
  failures journal as terminal-or-retryable per the SDK's
  `ctx.run` semantics. The Linear API itself is a `ctx.run`-side
  side effect.

  Reads `LINEAR_API_KEY` from the environment at call time. Endpoint
  override via the `:symphony_runtime, :linear_endpoint` app env
  (default `https://api.linear.app/graphql`).
  """

  alias Symphony.Core.Issue

  @default_endpoint "https://api.linear.app/graphql"
  @marker_prefix "symphony-restate:"

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

  @find_comments_query """
  query SymphonyFindComments($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 100, includeArchived: true) {
        nodes { id body }
      }
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

  @doc """
  Build a deterministic marker string for a per-turn Linear comment.

  Embedded as an HTML comment in the body so it is invisible to
  readers in Linear's UI but greppable via the API. Used by
  `post_comment_idempotent!/3` to detect a previously-posted
  comment and skip re-posting after a `ctx.run` retry where the
  HTTP response was lost before journaling.
  """
  @spec attempt_turn_marker(String.t(), pos_integer(), pos_integer()) :: String.t()
  def attempt_turn_marker(identifier, attempt_n, turn_n)
      when is_binary(identifier) and is_integer(attempt_n) and is_integer(turn_n) do
    "#{@marker_prefix}#{identifier}/a#{attempt_n}/t#{turn_n}"
  end

  @doc """
  Post a comment with idempotency: if a comment whose body contains
  `marker` already exists on the issue, return its id without
  posting. Otherwise, post and return the new id.

  This guards against the one residual non-idempotency in `ctx.run`:
  a side effect can complete on the server (Linear posts the comment)
  but the response can be lost before we journal it; on retry, the
  side effect would otherwise run a second time. Using a deterministic
  marker (typically `attempt_turn_marker/3`) lets the retry detect
  the prior write and reuse its id.
  """
  @spec post_comment_idempotent!(String.t(), String.t(), String.t()) :: String.t()
  def post_comment_idempotent!(issue_id, body, marker)
      when is_binary(issue_id) and is_binary(body) and is_binary(marker) do
    # Always include the marker in the body even on the search-or-create
    # path; this keeps reconciliation symmetric across replays.
    body_with_marker =
      if String.contains?(body, marker), do: body, else: body <> "\n\n<!-- #{marker} -->"

    case find_comment_by_marker(issue_id, marker) do
      {:ok, comment_id} when is_binary(comment_id) -> comment_id
      :not_found -> post_comment!(issue_id, body_with_marker)
    end
  end

  @doc false
  @spec find_comment_by_marker(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def find_comment_by_marker(issue_id, marker)
      when is_binary(issue_id) and is_binary(marker) do
    case graphql!(@find_comments_query, %{"issueId" => issue_id}) do
      %{"data" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        case Enum.find(nodes, fn %{"body" => b} -> is_binary(b) and String.contains?(b, marker) end) do
          %{"id" => id} -> {:ok, id}
          nil -> :not_found
        end

      %{"data" => %{"issue" => nil}} ->
        raise "linear_issue_not_found_for_comment_lookup: #{issue_id}"

      other ->
        raise "linear_comment_lookup_failed: #{inspect(other)}"
    end
  end

  @doc """
  Run an arbitrary Linear GraphQL operation. Non-raising — used by
  the `linear_graphql` codex dynamic tool, where errors must be
  returned to the agent as a structured tool failure rather than
  crashing the turn.

  Returns `{:ok, body}` on a successful HTTP exchange (even if the
  body contains GraphQL `errors` — surfacing those is the caller's
  job for tool semantics) or `{:error, reason}` on transport failure
  / missing auth / unexpected status.
  """
  @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables) when is_binary(query) and is_map(variables) do
    case System.get_env("LINEAR_API_KEY") do
      nil ->
        {:error, :missing_linear_api_token}

      api_key ->
        endpoint = Application.get_env(:symphony_runtime, :linear_endpoint, @default_endpoint)

        try do
          response =
            Req.post!(endpoint,
              headers: [
                {"authorization", api_key},
                {"content-type", "application/json"}
              ],
              json: %{"query" => query, "variables" => variables}
            )

          case response.status do
            status when status in 200..299 -> {:ok, response.body}
            status -> {:error, {:linear_api_status, status}}
          end
        rescue
          e -> {:error, {:linear_api_request, Exception.message(e)}}
        end
    end
  end

  defp graphql!(query, variables) do
    case graphql(query, variables) do
      {:ok, body} ->
        raise_on_errors!(body)
        body

      {:error, :missing_linear_api_token} ->
        raise "LINEAR_API_KEY env var is unset"

      {:error, reason} ->
        raise "linear_graphql_request_failed: #{inspect(reason)}"
    end
  end

  defp raise_on_errors!(%{"errors" => [_ | _] = errors}), do: raise("linear_graphql_error: #{inspect(errors)}")
  defp raise_on_errors!(_), do: :ok
end
