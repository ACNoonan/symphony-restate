defmodule Symphony.Runtime.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex `app-server` JSON-RPC stream over stdio.

  Slice 1.5 port of OpenAI Symphony's `SymphonyElixir.Codex.AppServer`
  (Apache-2.0). Stripped down to what's needed for one non-interactive
  turn: handshake → thread/start → turn/start → event stream →
  turn/completed. No SSH transport, no dynamic tools, no remote
  workspace policies. Auto-approves every approval request because the
  demo runs in workspace-write sandbox mode and there's no operator at
  the wheel.

  Slice 2 will replace this single-shot module with an OTP-supervised
  long-lived `Codex.Session` GenServer that keeps the port hot across
  multiple turns and re-attaches on node failover. For now each turn
  spawns and tears down its own port.

  ## Wire protocol (V0)

  Three request/response handshakes, then a streaming notification
  loop until terminal:

      → {"method":"initialize","id":1,...}
      ← {"id":1,"result":{...}}
      → {"method":"initialized","params":{}}
      → {"method":"thread/start","id":2,...}
      ← {"id":2,"result":{"thread":{"id":...}}}
      → {"method":"turn/start","id":3,...}
      ← {"id":3,"result":{"turn":{"id":...}}}
      ← {"method":"item/agentMessage","params":{"text":"..."}}
      ← ... approval requests / tool calls / message deltas ...
      ← {"method":"turn/completed", ...}      # success
        | {"method":"turn/failed",   ...}     # error
        | {"method":"turn/cancelled",...}     # cancellation

  Approvals received during the stream are auto-decided
  ("acceptForSession" for command/patch approvals, no-op answers for
  user-input requests).
  """

  require Logger

  @port_line_bytes 1_048_576
  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @default_read_timeout_ms 5_000
  @default_turn_timeout_ms 3_600_000
  @default_codex_command "codex app-server"
  @default_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_thread_sandbox "workspace-write"

  @type opts :: [
          codex_command: String.t(),
          read_timeout_ms: pos_integer(),
          turn_timeout_ms: pos_integer(),
          approval_policy: term(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map() | nil
        ]

  @type result :: %{
          text: String.t(),
          events: [map()],
          thread_id: String.t(),
          turn_id: String.t()
        }

  @type session :: %{port: port(), thread_id: String.t(), workspace: Path.t(), opts: opts()}

  @doc """
  Open a long-lived codex `app-server` session: spawn the port, run
  the JSON-RPC handshake (`initialize` + `thread/start`), and return
  the session struct. The caller owns the port; closing requires
  `stop/1`. Use this for slice 2's pinned `Codex.Session` GenServer.
  """
  @spec start(Path.t(), opts()) :: {:ok, session()} | {:error, term()}
  def start(workspace, opts \\ []) when is_binary(workspace) do
    with {:ok, port} <- start_port(workspace, opts),
         {:ok, thread_id} <- handshake(port, workspace, opts) do
      {:ok, %{port: port, thread_id: thread_id, workspace: workspace, opts: opts}}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Run one `turn/start` cycle on an already-open session and stream
  until terminal. Returns `{:ok, result}` on `turn/completed` (with
  accumulated agent text), or `{:error, reason}` on failure /
  cancellation / port death. The session remains open; close it with
  `stop/1`.
  """
  @spec turn(session(), String.t(), map(), opts()) :: {:ok, result()} | {:error, term()}
  def turn(%{port: port, thread_id: thread_id, workspace: workspace} = session, prompt, issue, opts \\ [])
      when is_binary(prompt) and is_map(issue) do
    merged_opts = Keyword.merge(session.opts, opts)

    case start_turn(port, thread_id, prompt, issue, workspace, merged_opts) do
      {:ok, turn_id} ->
        case stream_until_terminal(port, merged_opts) do
          {:ok, %{text: text, events: events}} ->
            {:ok, %{text: text, events: events, thread_id: thread_id, turn_id: turn_id}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Close an open codex session's port. Idempotent."
  @spec stop(session()) :: :ok
  def stop(%{port: port}), do: stop_port(port)

  @doc """
  Convenience wrapper: open a session, run one turn, close it.
  Used by slice 1.5's single-shot path; slice 2's `Codex.Session`
  GenServer prefers `start/2` + `turn/4` + `stop/1` to keep the port
  warm across turns.
  """
  @spec run(Path.t(), String.t(), map(), opts()) ::
          {:ok, result()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ [])
      when is_binary(workspace) and is_binary(prompt) and is_map(issue) do
    with {:ok, session} <- start(workspace, opts) do
      try do
        turn(session, prompt, issue, opts)
      after
        stop(session)
      end
    end
  end

  # --- Port lifecycle ---

  defp start_port(workspace, opts) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        cmd = Keyword.get(opts, :codex_command, @default_codex_command)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(bash)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(cmd)],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ -> try do
             Port.close(port)
             :ok
           rescue
             ArgumentError -> :ok
           end
    end
  end

  # --- Handshake ---

  defp handshake(port, workspace, opts) do
    with :ok <- send_initialize(port, opts),
         {:ok, thread_id} <- send_thread_start(port, workspace, opts) do
      {:ok, thread_id}
    end
  end

  defp send_initialize(port, opts) do
    send_message(port, %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{"experimentalApi" => true},
        "clientInfo" => %{
          "name" => "symphony-restate",
          "title" => "symphony-restate",
          "version" => "0.0.1"
        }
      }
    })

    case await_response(port, @initialize_id, read_timeout(opts)) do
      {:ok, _} ->
        send_message(port, %{"method" => "initialized", "params" => %{}})
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp send_thread_start(port, workspace, opts) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => Keyword.get(opts, :approval_policy, @default_approval_policy),
        "sandbox" => Keyword.get(opts, :thread_sandbox, @default_thread_sandbox),
        "cwd" => workspace,
        "dynamicTools" => []
      }
    })

    case await_response(port, @thread_start_id, read_timeout(opts)) do
      {:ok, %{"thread" => %{"id" => id}}} -> {:ok, id}
      {:ok, other} -> {:error, {:invalid_thread_payload, other}}
      {:error, _} = err -> err
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, opts) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => prompt}],
        "cwd" => workspace,
        "title" => "#{issue[:identifier] || issue["identifier"]}: #{issue[:title] || issue["title"]}",
        "approvalPolicy" => Keyword.get(opts, :approval_policy, @default_approval_policy),
        "sandboxPolicy" =>
          Keyword.get(opts, :turn_sandbox_policy, default_turn_sandbox_policy(workspace))
      }
    })

    case await_response(port, @turn_start_id, read_timeout(opts)) do
      {:ok, %{"turn" => %{"id" => id}}} -> {:ok, id}
      {:ok, other} -> {:error, {:invalid_turn_payload, other}}
      {:error, _} = err -> err
    end
  end

  defp default_turn_sandbox_policy(workspace) do
    %{"mode" => "workspaceWrite", "workspaceWrite" => %{"workspaceRoots" => [workspace]}}
  end

  # --- Stream loop ---

  defp stream_until_terminal(port, opts) do
    receive_loop(port, turn_timeout(opts), "", [], "")
  end

  defp receive_loop(port, timeout_ms, pending_line, events, accumulated_text) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        handle_line(port, line, timeout_ms, events, accumulated_text)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, timeout_ms, pending_line <> to_string(chunk), events, accumulated_text)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms -> {:error, :turn_timeout}
    end
  end

  defp handle_line(port, line, timeout_ms, events, accumulated_text) do
    case Jason.decode(line) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        {:ok, %{text: accumulated_text, events: Enum.reverse([payload | events])}}

      {:ok, %{"method" => "turn/failed"} = payload} ->
        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled"} = payload} ->
        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        case maybe_handle_approval(port, method, payload) do
          :handled ->
            receive_loop(port, timeout_ms, "", [payload | events], accumulated_text)

          :passthrough ->
            new_text = accumulated_text <> extract_agent_text(method, payload)
            receive_loop(port, timeout_ms, "", [payload | events], new_text)
        end

      {:ok, payload} ->
        receive_loop(port, timeout_ms, "", [payload | events], accumulated_text)

      {:error, _} ->
        log_non_json(line)
        receive_loop(port, timeout_ms, "", events, accumulated_text)
    end
  end

  # --- Approvals (auto-accept everything) ---

  @auto_accept_for_session ~w(
    item/commandExecution/requestApproval
    item/fileChange/requestApproval
    applyPatchApproval
    execCommandApproval
  )

  defp maybe_handle_approval(port, method, %{"id" => id} = _payload)
       when method in @auto_accept_for_session do
    decision =
      if method in ["execCommandApproval", "applyPatchApproval"],
        do: "approved_for_session",
        else: "acceptForSession"

    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})
    :handled
  end

  defp maybe_handle_approval(port, "item/tool/call", %{"id" => id} = _payload) do
    # Slice 1.5 has no dynamic tools registered. If codex calls one
    # anyway we reply with a structured failure so it can move on.
    send_message(port, %{
      "id" => id,
      "result" => %{
        "success" => false,
        "output" => "no dynamic tools registered (slice 1.5)",
        "contentItems" => [
          %{"type" => "inputText", "text" => "no dynamic tools registered (slice 1.5)"}
        ]
      }
    })

    :handled
  end

  defp maybe_handle_approval(port, "item/tool/requestUserInput", %{
         "id" => id,
         "params" => %{"questions" => questions}
       })
       when is_list(questions) do
    answers =
      Map.new(questions, fn
        %{"id" => qid} ->
          {qid,
           %{
             "answers" => ["This is a non-interactive session. Operator input is unavailable."]
           }}
      end)

    send_message(port, %{"id" => id, "result" => %{"answers" => answers}})
    :handled
  end

  defp maybe_handle_approval(_port, _method, _payload), do: :passthrough

  # --- Agent text extraction ---
  #
  # Codex emits a few message-type events as the model speaks. We
  # accumulate any `text` fields from `item/agentMessage*` notifications
  # and the `lastMessage` field on `turn/completed`. Defensive against
  # schema drift — anything we don't recognize is ignored, never raises.

  defp extract_agent_text(method, %{"params" => params}) when is_map(params) do
    cond do
      String.starts_with?(method, "item/agentMessage") ->
        text_of(params)

      method == "item/messageDelta" ->
        text_of(params)

      true ->
        ""
    end
  end

  defp extract_agent_text(_method, _payload), do: ""

  defp text_of(params) do
    case params do
      %{"text" => t} when is_binary(t) -> t
      %{"delta" => %{"text" => t}} when is_binary(t) -> t
      %{"message" => %{"text" => t}} when is_binary(t) -> t
      _ -> ""
    end
  end

  # --- Wire utilities ---

  defp send_message(port, message) do
    Port.command(port, [Jason.encode!(message), "\n"])
  end

  defp await_response(port, request_id, timeout_ms) do
    do_await_response(port, request_id, timeout_ms, "")
  end

  defp do_await_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        do_await_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms -> {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, line, timeout_ms) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^request_id, "result" => result}} -> {:ok, result}
      {:ok, %{"id" => ^request_id, "error" => error}} -> {:error, {:response_error, error}}
      {:ok, %{"id" => ^request_id} = other} -> {:error, {:response_error, other}}
      {:ok, _other} -> do_await_response(port, request_id, timeout_ms, "")
      {:error, _} ->
        log_non_json(line)
        do_await_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json(line) do
    text = line |> to_string() |> String.trim() |> String.slice(0, 500)

    if text != "" do
      Logger.debug("codex non-json line: #{text}")
    end
  end

  defp read_timeout(opts), do: Keyword.get(opts, :read_timeout_ms, @default_read_timeout_ms)
  defp turn_timeout(opts), do: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms)
end
