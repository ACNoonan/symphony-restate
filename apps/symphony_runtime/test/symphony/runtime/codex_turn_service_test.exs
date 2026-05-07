defmodule Symphony.Runtime.CodexTurnServiceTest do
  use ExUnit.Case, async: true

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.Invocation
  alias Symphony.Runtime.CodexTurnService

  defp run(start, input, mfa, replay \\ []) do
    replay_frames =
      Enum.map(replay, fn msg ->
        %Restate.Protocol.Frame{type: 0, flags: 0, message: msg}
      end)

    {:ok, pid} = Invocation.start_link({start, input, replay_frames, mfa, %{}})
    {_outcome, body} = Invocation.await_response(pid)
    {:ok, frames, ""} = Framer.decode_all(body)
    Enum.map(frames, & &1.message)
  end

  defp valid_input(overrides \\ %{}) do
    Map.merge(
      %{
        "identifier" => "SYM-1",
        "workspace_path" => "/tmp/SYM-1",
        "prompt" => "do the thing",
        "conversation_so_far" => [],
        "issue_meta" => %{"identifier" => "SYM-1", "title" => "test issue"},
        "codex_opts" => %{}
      },
      overrides
    )
  end

  describe "run/2 ctx.run replay" do
    test "happy path: replay journaled %{text: ...} → handler returns it" do
      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"text" => "hello world"})}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{},
                 valid_input(),
                 {CodexTurnService, :run, 2},
                 replay
               )

      assert Jason.decode!(out) == %{"text" => "hello world"}
    end

    test "empty-text branch: replay journaled placeholder map → handler returns it" do
      placeholder =
        "[symphony-restate] codex turn completed without an extractable agent message; check the Restate journal for raw events."

      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"text" => placeholder})}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{},
                 valid_input(),
                 {CodexTurnService, :run, 2},
                 replay
               )

      assert Jason.decode!(out) == %{"text" => placeholder}
    end

    test "failure branch: replay journals failure → handler propagates terminal" do
      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result:
            {:failure,
             %Pb.Failure{code: 500, message: "codex_turn_failed: {:port_exit, 137}"}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{},
                 valid_input(),
                 {CodexTurnService, :run, 2},
                 replay
               )

      assert msg =~ "codex_turn_failed"
    end
  end

  describe "run/2 input validation (no replay)" do
    test "rejects missing identifier" do
      input = valid_input() |> Map.delete("identifier")

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, input, {CodexTurnService, :run, 2})

      assert msg =~ "invalid_codex_turn_input"
      assert msg =~ "identifier"
    end

    test "rejects missing workspace_path" do
      input = valid_input() |> Map.delete("workspace_path")

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, input, {CodexTurnService, :run, 2})

      assert msg =~ "invalid_codex_turn_input"
      assert msg =~ "workspace_path"
    end

    test "rejects missing prompt" do
      input = valid_input() |> Map.delete("prompt")

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, input, {CodexTurnService, :run, 2})

      assert msg =~ "invalid_codex_turn_input"
      assert msg =~ "prompt"
    end
  end

  describe "input transformers (pure helpers)" do
    test "atomize_issue_meta/1 with string keys" do
      assert CodexTurnService.atomize_issue_meta(%{
               "identifier" => "SYM-1",
               "title" => "build the thing"
             }) == %{identifier: "SYM-1", title: "build the thing"}
    end

    test "atomize_issue_meta/1 with atom keys" do
      assert CodexTurnService.atomize_issue_meta(%{
               identifier: "SYM-1",
               title: "build the thing"
             }) == %{identifier: "SYM-1", title: "build the thing"}
    end

    test "atomize_issue_meta/1 defaults missing title to empty string" do
      assert CodexTurnService.atomize_issue_meta(%{"identifier" => "SYM-1"}) ==
               %{identifier: "SYM-1", title: ""}
    end

    test "decode_codex_opts/1 picks known keys, atomizes, drops unknowns" do
      input = %{
        "turn_timeout_ms" => 5_000,
        "codex_command" => "codex app-server",
        "thread_sandbox" => "workspace-write",
        "made_up_option" => "ignored"
      }

      result = CodexTurnService.decode_codex_opts(input)

      assert is_list(result)
      assert {:turn_timeout_ms, 5_000} in result
      assert {:codex_command, "codex app-server"} in result
      assert {:thread_sandbox, "workspace-write"} in result
      refute Enum.any?(result, fn {k, _v} -> k == :made_up_option end)
    end

    test "decode_codex_opts/1 returns [] for empty map" do
      assert CodexTurnService.decode_codex_opts(%{}) == []
    end

    test "decode_codex_opts/1 returns [] for non-map input" do
      assert CodexTurnService.decode_codex_opts(nil) == []
      assert CodexTurnService.decode_codex_opts("not a map") == []
    end

    test "decode_conversation/1 converts string-keyed records to atom-keyed" do
      input = [
        %{"turn" => 1, "prompt" => "do x", "response" => "did x"},
        %{"turn" => 2, "prompt" => "do y", "response" => "did y"}
      ]

      assert CodexTurnService.decode_conversation(input) == [
               %{turn: 1, prompt: "do x", response: "did x"},
               %{turn: 2, prompt: "do y", response: "did y"}
             ]
    end

    test "decode_conversation/1 preserves order — Codex.Session relies on it for cold-path seeding" do
      input = [
        %{"turn" => 1, "prompt" => "first", "response" => "r1"},
        %{"turn" => 2, "prompt" => "second", "response" => "r2"},
        %{"turn" => 3, "prompt" => "third", "response" => "r3"}
      ]

      result = CodexTurnService.decode_conversation(input)
      assert Enum.map(result, & &1.turn) == [1, 2, 3]
      assert Enum.map(result, & &1.prompt) == ["first", "second", "third"]
    end

    test "decode_conversation/1 returns [] for empty list" do
      assert CodexTurnService.decode_conversation([]) == []
    end

    test "decode_conversation/1 returns [] for non-list input" do
      assert CodexTurnService.decode_conversation(nil) == []
      assert CodexTurnService.decode_conversation(%{}) == []
    end
  end
end
