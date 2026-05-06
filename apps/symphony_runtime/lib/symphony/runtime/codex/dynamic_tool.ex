defmodule Symphony.Runtime.Codex.DynamicTool do
  @moduledoc """
  Client-side dynamic tools advertised to codex on `thread/start`
  and dispatched from `item/tool/call` notifications.

  Slice 2.5 ships one tool: `linear_graphql` — a passthrough to the
  Linear GraphQL endpoint using Symphony's configured auth. Lets the
  agent drive its own ticket: query the issue, post comments, update
  state, follow blocked-by relations.

  Mirrors `SymphonyElixir.Codex.DynamicTool` from the upstream
  reference (Apache-2.0). The tool wire shape and arguments
  schema are kept compatible so a WORKFLOW.md written for upstream
  Symphony works here.
  """

  alias Symphony.Runtime.Linear

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using
  symphony-restate's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @doc """
  Dynamic tool specs to advertise on `thread/start`.
  Wire shape mirrors upstream Symphony's `DynamicTool.tool_specs/0`.
  """
  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  @doc """
  Execute one tool call. Always returns the JSON-RPC `result` map
  (`%{"success" => bool, "output" => str, "contentItems" => [...]}`)
  expected by codex — failures are returned as `success: false`,
  not raised, so the turn can continue.
  """
  @spec execute(String.t() | nil, term()) :: map()
  def execute(@linear_graphql_tool, arguments), do: execute_linear_graphql(arguments)

  def execute(other, _arguments) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(other)}.",
        "supportedTools" => Enum.map(tool_specs(), & &1["name"])
      }
    })
  end

  defp execute_linear_graphql(arguments) do
    with {:ok, query, variables} <- normalize_arguments(arguments),
         {:ok, response} <- Linear.graphql(query, variables) do
      success =
        case response do
          %{"errors" => errors} when is_list(errors) and errors != [] -> false
          _ -> true
        end

      response_body(success, response)
    else
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_arguments(_), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      vars when is_map(vars) -> {:ok, vars}
      _ -> {:error, :invalid_variables}
    end
  end

  defp response_body(success, payload) do
    output = encode(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp failure_response(payload), do: response_body(false, payload)

  defp encode(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode(payload), do: inspect(payload)

  defp error_payload(:missing_query) do
    %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  end

  defp error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" =>
          "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp error_payload(:invalid_variables) do
    %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  end

  defp error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" =>
          "symphony-restate is missing Linear auth. Set `LINEAR_API_KEY` in the BEAM node's environment."
      }
    }
  end

  defp error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end
end
