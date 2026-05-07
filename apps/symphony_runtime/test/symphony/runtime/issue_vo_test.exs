defmodule Symphony.Runtime.IssueVOTest do
  use ExUnit.Case, async: true

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.Invocation
  alias Symphony.Runtime.IssueVO

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

  defp running_issue_state(attempt_n) do
    [
      %Pb.StartMessage.StateEntry{
        key: "last_attempt_n",
        value: encode_state(attempt_n)
      },
      %Pb.StartMessage.StateEntry{
        key: "claim_status",
        value: encode_state("running")
      }
    ]
  end

  describe "cancel/2" do
    test "forwards to RunAttemptWorkflow.cancel and merges identifier+attempt_n" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: running_issue_state(3)
      }

      workflow_response = %{
        "ok" => true,
        "target_invocation_id" => "inv_xyz",
        "workflow_key" => "SYM-1::a3"
      }

      replay = [
        %Pb.CallCommandMessage{
          service_name: "RunAttemptWorkflow",
          handler_name: "cancel",
          key: "SYM-1::a3",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 1,
          invocation_id: "inv_workflow"
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(workflow_response)}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {IssueVO, :cancel, 2}, replay)

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["target_invocation_id"] == "inv_xyz"
      assert response["workflow_key"] == "SYM-1::a3"
      assert response["identifier"] == "SYM-1"
      assert response["attempt_n"] == 3
    end

    test "rejects when claim_status is not running" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: [
          %Pb.StartMessage.StateEntry{
            key: "last_attempt_n",
            value: encode_state(2)
          },
          %Pb.StartMessage.StateEntry{
            key: "claim_status",
            value: encode_state("done")
          }
        ]
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {IssueVO, :cancel, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "not_running",
               "claim_status" => "done",
               "identifier" => "SYM-1"
             }
    end

    test "rejects when no attempt has been recorded" do
      start = %Pb.StartMessage{key: "SYM-1"}

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {IssueVO, :cancel, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "no_attempt",
               "identifier" => "SYM-1"
             }
    end
  end

  describe "nudge/2" do
    test "forwards to RunAttemptWorkflow.nudge and merges identifier+attempt_n" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: running_issue_state(2)
      }

      workflow_response = %{
        "ok" => true,
        "key" => "nudge:0000001715000000000:42",
        "workflow_key" => "SYM-1::a2"
      }

      replay = [
        %Pb.CallCommandMessage{
          service_name: "RunAttemptWorkflow",
          handler_name: "nudge",
          key: "SYM-1::a2",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 1,
          invocation_id: "inv_nudge_call"
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(workflow_response)}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => "tweak"}, {IssueVO, :nudge, 2}, replay)

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["key"] == "nudge:0000001715000000000:42"
      assert response["identifier"] == "SYM-1"
      assert response["attempt_n"] == 2
    end

    test "rejects empty text without making the workflow call" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: running_issue_state(1)
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => ""}, {IssueVO, :nudge, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "missing_or_empty_text",
               "identifier" => "SYM-1"
             }
    end
  end

  describe "nudge_now/2" do
    test "forwards to RunAttemptWorkflow.nudge_now and merges identifier+attempt_n" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: running_issue_state(4)
      }

      workflow_response = %{
        "ok" => true,
        "interrupted" => true,
        "key" => "nudge:0000001715000000000:99",
        "workflow_key" => "SYM-1::a4"
      }

      replay = [
        %Pb.CallCommandMessage{
          service_name: "RunAttemptWorkflow",
          handler_name: "nudge_now",
          key: "SYM-1::a4",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 1,
          invocation_id: "inv_nudge_now_call"
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(workflow_response)}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 start,
                 %{"text" => "abort and pivot"},
                 {IssueVO, :nudge_now, 2},
                 replay
               )

      response = Jason.decode!(out)
      assert response["ok"] == true
      assert response["interrupted"] == true
      assert response["identifier"] == "SYM-1"
      assert response["attempt_n"] == 4
    end

    test "rejects when not running" do
      start = %Pb.StartMessage{
        key: "SYM-1",
        state_map: [
          %Pb.StartMessage.StateEntry{
            key: "last_attempt_n",
            value: encode_state(1)
          },
          %Pb.StartMessage.StateEntry{
            key: "claim_status",
            value: encode_state("failed")
          }
        ]
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, %{"text" => "anything"}, {IssueVO, :nudge_now, 2})

      assert Jason.decode!(out) == %{
               "ok" => false,
               "reason" => "not_running",
               "claim_status" => "failed",
               "identifier" => "SYM-1"
             }
    end
  end

  describe "dispatch/2 rescue mapping" do
    # Drive dispatch to the rescue path via a journaled workflow call
    # that resolves with a TerminalError. The replay frames are
    # consumed by the SDK as the handler reaches each command — only
    # commands emitted *after* replay exhaustion appear in the output.
    # SetState commands match by message type only (not key/value), so
    # the replay can use placeholder bytes for the pre-call state
    # writes (last_attempt_n, claim_status="running", worker_node).
    test "TerminalError{code: 409} → claim_status=\"cancelled\" output" do
      start = %Pb.StartMessage{key: "SYM-2"}

      replay = [
        # Three pre-call SetStates emitted before the workflow call.
        %Pb.SetStateCommandMessage{key: "last_attempt_n", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "claim_status", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "worker_node", value: %Pb.Value{content: ""}},
        # The Call to RunAttemptWorkflow.run.
        %Pb.CallCommandMessage{
          service_name: "RunAttemptWorkflow",
          handler_name: "run",
          key: "SYM-2::a1",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        # Notification: the workflow failed with 409 (cancel cascade).
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
        }
      ]

      assert [
               %Pb.SetStateCommandMessage{
                 key: "claim_status",
                 value: %Pb.Value{content: status_cancelled_bytes}
               },
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] = run(start, nil, {IssueVO, :dispatch, 2}, replay)

      assert Jason.decode!(status_cancelled_bytes) == "cancelled"
    end

    test "TerminalError with other code → claim_status=\"failed\" output" do
      start = %Pb.StartMessage{key: "SYM-3"}

      replay = [
        %Pb.SetStateCommandMessage{key: "last_attempt_n", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "claim_status", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "worker_node", value: %Pb.Value{content: ""}},
        %Pb.CallCommandMessage{
          service_name: "RunAttemptWorkflow",
          handler_name: "run",
          key: "SYM-3::a1",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:failure, %Pb.Failure{code: 500, message: "codex_turn_stall: ..."}}
        }
      ]

      assert [
               %Pb.SetStateCommandMessage{
                 key: "claim_status",
                 value: %Pb.Value{content: status_failed_bytes}
               },
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500}}
               },
               %Pb.EndMessage{}
             ] = run(start, nil, {IssueVO, :dispatch, 2}, replay)

      assert Jason.decode!(status_failed_bytes) == "failed"
    end
  end
end
