defmodule Symphony.Runtime.RunAttemptWorkflowTest do
  use ExUnit.Case, async: true

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.Invocation
  alias Symphony.Runtime.RunAttemptWorkflow

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

  defp encode_state(value), do: Jason.encode!(value)

  describe "cancel/2" do
    test "emits SendSignal{idx: 1, target} when current_turn_invocation_id is set" do
      start = %Pb.StartMessage{
        key: "SYM-1::a1",
        state_map: [
          %Pb.StartMessage.StateEntry{
            key: "current_turn_invocation_id",
            value: encode_state("inv_target_xyz")
          }
        ]
      }

      assert [
               %Pb.SendSignalCommandMessage{
                 target_invocation_id: "inv_target_xyz",
                 signal_id: {:idx, 1},
                 result: {:void, %Pb.Void{}}
               },
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {RunAttemptWorkflow, :cancel, 2})

      assert Jason.decode!(out) == %{
               "ok" => true,
               "target_invocation_id" => "inv_target_xyz",
               "workflow_key" => "SYM-1::a1"
             }
    end

    test "returns no_active_turn when state slot is empty" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {RunAttemptWorkflow, :cancel, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "no_active_turn",
               "workflow_key" => "SYM-1::a1"
             }
    end
  end

  describe "nudge/2" do
    test "emits SetState with nudge:* key + ok response when text is non-empty" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.SetStateCommandMessage{key: state_key, value: %Pb.Value{content: stored}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 start,
                 %{"text" => "tweak the prompt"},
                 {RunAttemptWorkflow, :nudge, 2}
               )

      assert String.starts_with?(state_key, "nudge:")
      assert %{"text" => "tweak the prompt", "received_at_ms" => ms} = Jason.decode!(stored)
      assert is_integer(ms) and ms > 0

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["key"] == state_key
      assert response["workflow_key"] == "SYM-1::a1"
    end

    test "rejects empty text" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => ""}, {RunAttemptWorkflow, :nudge, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "missing_or_empty_text",
               "workflow_key" => "SYM-1::a1"
             }
    end

    test "rejects payload missing text key" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"wrong" => "shape"}, {RunAttemptWorkflow, :nudge, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "missing_or_empty_text",
               "workflow_key" => "SYM-1::a1"
             }
    end
  end

  describe "nudge_now/2" do
    test "emits SetState + CompleteAwakeable when current_nudge_now_awakeable_id is set" do
      awakeable_id = "sign_1abc"

      start = %Pb.StartMessage{
        key: "SYM-1::a1",
        state_map: [
          %Pb.StartMessage.StateEntry{
            key: "current_nudge_now_awakeable_id",
            value: encode_state(awakeable_id)
          }
        ]
      }

      assert [
               %Pb.SetStateCommandMessage{key: state_key, value: %Pb.Value{content: stored}},
               %Pb.CompleteAwakeableCommandMessage{
                 awakeable_id: ^awakeable_id,
                 result: {:value, %Pb.Value{content: completion_value}}
               },
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 start,
                 %{"text" => "stop and rethink"},
                 {RunAttemptWorkflow, :nudge_now, 2}
               )

      assert String.starts_with?(state_key, "nudge:")

      assert %{"text" => "stop and rethink", "via" => "nudge_now"} =
               Jason.decode!(stored)

      assert Jason.decode!(completion_value) == "nudge_now_redirect"

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["interrupted"] == true
      assert response["key"] == state_key
    end

    test "stages text without completing awakeable when no turn is in flight" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.SetStateCommandMessage{key: state_key, value: %Pb.Value{content: stored}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => "queued"}, {RunAttemptWorkflow, :nudge_now, 2})

      assert String.starts_with?(state_key, "nudge:")
      assert %{"text" => "queued", "via" => "nudge_now"} = Jason.decode!(stored)

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["interrupted"] == false
      assert response["queued_only"] == true
    end

    test "rejects empty text" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => ""}, {RunAttemptWorkflow, :nudge_now, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "missing_or_empty_text",
               "workflow_key" => "SYM-1::a1"
             }
    end
  end

  describe "read_state/2" do
    test "exposes state slots that the run handler writes during a turn" do
      start = %Pb.StartMessage{
        key: "SYM-1::a1",
        state_map: [
          %Pb.StartMessage.StateEntry{
            key: "workflow_content_hash",
            value: encode_state("abc123")
          },
          %Pb.StartMessage.StateEntry{
            key: "workspace_path",
            value: encode_state("/tmp/SYM-1")
          },
          %Pb.StartMessage.StateEntry{
            key: "conversation",
            value:
              encode_state([
                %{"turn" => 1, "prompt" => "hi", "response" => "hello"}
              ])
          },
          %Pb.StartMessage.StateEntry{
            key: "turn_count",
            value: encode_state(1)
          },
          %Pb.StartMessage.StateEntry{
            key: "last_comment_id",
            value: encode_state("comment-1")
          }
        ]
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {RunAttemptWorkflow, :read_state, 2})

      response = Jason.decode!(out)
      assert response["workflow_key"] == "SYM-1::a1"
      assert response["workflow_content_hash"] == "abc123"
      assert response["workspace_path"] == "/tmp/SYM-1"
      assert response["conversation"] == [%{"turn" => 1, "prompt" => "hi", "response" => "hello"}]
      assert response["turn_count"] == 1
      assert response["last_comment_id"] == "comment-1"
    end

    test "returns nils + empty conversation when state is unset" do
      start = %Pb.StartMessage{key: "SYM-1::a1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {RunAttemptWorkflow, :read_state, 2})

      assert Jason.decode!(out) == %{
               "workflow_key" => "SYM-1::a1",
               "workflow_content_hash" => nil,
               "workspace_path" => nil,
               "conversation" => [],
               "turn_count" => nil,
               "last_comment_id" => nil
             }
    end
  end
end
