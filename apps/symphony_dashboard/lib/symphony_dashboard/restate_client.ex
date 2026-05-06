defmodule Symphony.Dashboard.RestateClient do
  @moduledoc """
  Thin HTTP client for Restate ingress (default `http://localhost:8080`).

  The dashboard reads state by calling our own `:shared` /
  observability handlers via the ingress — no direct journal access,
  no admin API. Every read goes through Restate's normal request
  path so what the dashboard sees is exactly what any other client
  would see, which keeps the demo's "Restate is the source of
  truth" story honest.

  ## URL shape

  Restate ingress URLs are
  `<ingress>/<service>/[<key>/]<handler>`. Plain Services skip the
  key segment; Virtual Objects and Workflows include it
  URI-encoded.

  All calls are POSTs with a JSON body. `nil` payload becomes the
  literal `null` (which our shared handlers treat as no input).
  """

  require Logger

  @type response :: {:ok, term()} | {:error, term()}

  @doc "Call a plain Service handler."
  @spec service_call(String.t(), String.t(), term()) :: response()
  def service_call(service, handler, payload \\ nil)
      when is_binary(service) and is_binary(handler) do
    post(path([service, handler]), payload)
  end

  @doc "Call a Virtual Object handler keyed on `key`."
  @spec object_call(String.t(), String.t(), String.t(), term()) :: response()
  def object_call(service, key, handler, payload \\ nil)
      when is_binary(service) and is_binary(key) and is_binary(handler) do
    post(path([service, URI.encode_www_form(key), handler]), payload)
  end

  @doc "Call a Workflow handler keyed on `workflow_key`."
  @spec workflow_call(String.t(), String.t(), String.t(), term()) :: response()
  def workflow_call(service, workflow_key, handler, payload \\ nil)
      when is_binary(service) and is_binary(workflow_key) and is_binary(handler) do
    post(path([service, URI.encode_www_form(workflow_key), handler]), payload)
  end

  # ---------------------- Convenience wrappers ----------------------

  @doc "Snapshot the project's per-issue VO state via reconcile."
  @spec scheduler_reconcile(String.t()) :: response()
  def scheduler_reconcile(project_slug) when is_binary(project_slug) do
    object_call("SchedulerVO", project_slug, "reconcile")
  end

  @doc "Read one issue's VO state."
  @spec issue_read_state(String.t()) :: response()
  def issue_read_state(identifier) when is_binary(identifier) do
    object_call("IssueVO", identifier, "readState")
  end

  @doc """
  Read one attempt's workflow state. `attempt_n` is the integer
  attempt number from the issue's `last_attempt_n`; the workflow
  key follows the `IssueVO.attempt_workflow_key/2` convention.
  """
  @spec attempt_read_state(String.t(), pos_integer()) :: response()
  def attempt_read_state(identifier, attempt_n)
      when is_binary(identifier) and is_integer(attempt_n) and attempt_n > 0 do
    workflow_call(
      "RunAttemptWorkflow",
      "#{identifier}::a#{attempt_n}",
      "readState"
    )
  end

  # ---------------------- Internals ----------------------

  defp path(segments) do
    "/" <> Enum.join(segments, "/")
  end

  defp post(path, payload) do
    url = ingress() <> path
    body = if is_nil(payload), do: "null", else: Jason.encode!(payload)

    try do
      response =
        Req.post!(url,
          headers: [{"content-type", "application/json"}],
          body: body,
          receive_timeout: 5_000
        )

      case response.status do
        s when s in 200..299 ->
          # Restate ingress returns the handler's JSON-encoded result body.
          # Req auto-decodes on `application/json`, so `response.body` is
          # already a decoded term in the common case. Be defensive: if a
          # raw binary slips through, decode it ourselves.
          {:ok, decode_body(response.body)}

        s ->
          Logger.warning(fn -> "restate ingress #{path} → HTTP #{s}: #{inspect(response.body)}" end)
          {:error, {:restate_status, s, response.body}}
      end
    rescue
      e -> {:error, {:restate_request, Exception.message(e)}}
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, term} -> term
      {:error, _} -> body
    end
  end

  defp decode_body(other), do: other

  defp ingress do
    Application.fetch_env!(:symphony_dashboard, :restate_ingress)
  end
end
