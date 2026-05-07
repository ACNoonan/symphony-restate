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

  describe "run/2 input validation (no replay)" do
    test "rejects missing identifier" do
      input = %{
        "attempt_n" => 1,
        "workflow_path" => "/dev/null",
        "workspace_root" => "/tmp"
      }

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2}
               )

      assert msg =~ "invalid_workflow_input"
      assert msg =~ "identifier"
    end

    test "rejects missing attempt_n" do
      input = %{
        "identifier" => "SYM-1",
        "workflow_path" => "/dev/null",
        "workspace_root" => "/tmp"
      }

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2}
               )

      assert msg =~ "invalid_workflow_input"
      assert msg =~ "attempt_n"
    end

    test "rejects non-positive attempt_n" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 0,
        "workflow_path" => "/dev/null",
        "workspace_root" => "/tmp"
      }

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2}
               )

      assert msg =~ "invalid_workflow_input"
      assert msg =~ "attempt_n"
    end
  end

  describe "run/2 happy path (max_turns=1, single turn → ended_by=max_turns)" do
    @parsed_workflow %{
      "config" => %{
        "agent" => %{"max_turns" => 1},
        "tracker" => %{"terminal_states" => ["done", "closed"]}
      },
      "prompt_template" => "Issue: {{ issue.identifier }}",
      "content_hash" => "abc123"
    }

    @issue_map %{
      "id" => "uuid-issue-1",
      "identifier" => "SYM-1",
      "title" => "test issue",
      "description" => "",
      "priority" => 0,
      "state" => "Backlog",
      "branch_name" => "sym-1/test",
      "url" => "https://linear.app/x/SYM-1",
      "labels" => [],
      "blocked_by" => [],
      "created_at" => nil,
      "updated_at" => nil
    }

    @workspace_path Path.join(
                      System.tmp_dir!(),
                      "symphony-restate-test-runs/SYM-1::a1"
                    )

    @rendered_prompt "Issue: SYM-1"
    @turn_text "agent did the thing"
    @comment_id "linear-comment-uuid-1"
    @turn_invocation_id "inv_codex_turn_xyz"

    setup do
      File.rm_rf!(@workspace_path)
      :ok
    end

    test "drives one turn end-to-end and exits with ended_by=max_turns" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      replay = [
        # 1. ctx.run for load_workflow_pinned
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(@parsed_workflow)}}
        },
        # 2. SetState for workflow_content_hash
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        # 3. ctx.run for fetch_issue
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        # 4. ctx.run for Workspace.path_for
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        # 5. SetState for workspace_path
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        },
        # 6. ctx.run for prompt render
        %Pb.RunCommandMessage{result_completion_id: 4},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 4,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        # 7. CallCommand for CodexTurnService (cids 5 + 6)
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 5,
          result_completion_id: 6
        },
        # 8. CallInvocationIdNotification for cid 5
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 5,
          invocation_id: @turn_invocation_id
        },
        # 9. SetState for current_turn_invocation_id
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        # (Awakeable allocation: no journal entry)
        # 10. SetState for current_nudge_now_awakeable_id
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        # 11. SleepCommand for stall timer (cid 7)
        %Pb.SleepCommandMessage{
          wake_up_time: 0,
          result_completion_id: 7
        },
        # 12. CallCompletionNotification for the codex turn (cid 6)
        %Pb.CallCompletionNotificationMessage{
          completion_id: 6,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"text" => @turn_text})}}
        },
        # 13. ClearState for current_turn_invocation_id
        %Pb.ClearStateCommandMessage{key: "current_turn_invocation_id"},
        # 14. ctx.run for Linear.post_comment_idempotent! (cid 8)
        %Pb.RunCommandMessage{result_completion_id: 8},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 8,
          result: {:value, %Pb.Value{content: Jason.encode!(@comment_id)}}
        },
        # 15. SetState for conversation
        %Pb.SetStateCommandMessage{key: "conversation", value: %Pb.Value{content: ""}},
        # 16. SetState for turn_count
        %Pb.SetStateCommandMessage{key: "turn_count", value: %Pb.Value{content: ""}},
        # 17. SetState for last_comment_id
        %Pb.SetStateCommandMessage{key: "last_comment_id", value: %Pb.Value{content: ""}},
        # 18. ctx.run for Manager.stop_session (cid 9)
        %Pb.RunCommandMessage{result_completion_id: 9},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 9,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2},
                 replay
               )

      assert Jason.decode!(out) == %{
               "ok" => true,
               "identifier" => "SYM-1",
               "attempt_n" => 1,
               "issue_id" => "uuid-issue-1",
               "turns" => 1,
               "ended_by" => "max_turns",
               "workflow_content_hash" => "abc123"
             }

      # Workspace.preflight_local! ran for real outside ctx.run; verify
      # the directory was created on this BEAM node.
      assert File.dir?(@workspace_path)
    end

    test "cancel cascade: turn resolves with 409 → rescue → terminal cancelled_by_operator" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      replay = [
        # Setup phase identical to happy path: load workflow, fetch issue,
        # compute workspace, render prompt, dispatch codex turn.
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(@parsed_workflow)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 4},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 4,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 5,
          result_completion_id: 6
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 5,
          invocation_id: @turn_invocation_id
        },
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 7},
        # Cancel cascade: the codex turn invocation was cancelled, the
        # Restate runtime sends back a 409 failure on its result cid.
        %Pb.CallCompletionNotificationMessage{
          completion_id: 6,
          result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
        },
        # Awaitable.any raises 409, the rescue runs Manager.stop_session
        # inside ctx.run (fresh cid 8) before clearing state and raising
        # terminal cancelled_by_operator.
        %Pb.RunCommandMessage{result_completion_id: 8},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 8,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        },
        %Pb.ClearStateCommandMessage{key: "current_turn_invocation_id"}
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2},
                 replay
               )

      assert msg =~ "cancelled_by_operator"
    end

    test "tracker terminal: refetched issue moves to Done → ended_by=tracker_terminal" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      # Need max_turns >= 2 so the workflow reaches the post-turn
      # fetch_issue + terminal-state check (with max_turns=1 the
      # cond hits the halt-by-max_turns branch first).
      parsed_workflow_max2 =
        put_in(@parsed_workflow, ["config", "agent", "max_turns"], 2)

      issue_done = Map.put(@issue_map, "state", "Done")

      replay = [
        # Setup phase identical to happy path through the turn-1 race.
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(parsed_workflow_max2)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 4},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 4,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 5,
          result_completion_id: 6
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 5,
          invocation_id: @turn_invocation_id
        },
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 7},
        %Pb.CallCompletionNotificationMessage{
          completion_id: 6,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"text" => @turn_text})}}
        },
        %Pb.ClearStateCommandMessage{key: "current_turn_invocation_id"},
        %Pb.RunCommandMessage{result_completion_id: 8},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 8,
          result: {:value, %Pb.Value{content: Jason.encode!(@comment_id)}}
        },
        %Pb.SetStateCommandMessage{key: "conversation", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "turn_count", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "last_comment_id", value: %Pb.Value{content: ""}},
        # Mid-attempt fetch_issue: tracker has flipped to Done.
        %Pb.RunCommandMessage{result_completion_id: 9},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 9,
          result: {:value, %Pb.Value{content: Jason.encode!(issue_done)}}
        },
        # Halt → post-loop Manager.stop_session.
        %Pb.RunCommandMessage{result_completion_id: 10},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 10,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2},
                 replay
               )

      assert Jason.decode!(out) == %{
               "ok" => true,
               "identifier" => "SYM-1",
               "attempt_n" => 1,
               "issue_id" => "uuid-issue-1",
               "turns" => 1,
               "ended_by" => "tracker_terminal",
               "final_state" => "Done",
               "workflow_content_hash" => "abc123"
             }
    end

    test "pending nudges from prior turns are drained and prepended to next prompt" do
      # Seed `nudge:*` keys in the StartMessage state_map. Run the
      # replay through the workspace_path SetState; the workflow then
      # exits replay mode at `drain_pending_nudges`, emits fresh
      # ClearStateCommand frames for each nudge key, and runs the
      # prompt-render ctx.run *for real*. The handler suspends after
      # proposing the run completion — we assert the proposed value
      # carries the prepended operator interjection.
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      nudge_key = "nudge:0000001715000000000:42"

      nudge_payload = %{
        "text" => "be careful with the auth flow",
        "received_at_ms" => 1_715_000_000_000
      }

      start =
        %Pb.StartMessage{
          key: "SYM-1::a1",
          state_map: [
            %Pb.StartMessage.StateEntry{
              key: nudge_key,
              value: Jason.encode!(nudge_payload)
            }
          ]
        }

      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(@parsed_workflow)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        }
        # Replay ends here. Next ops run fresh in :processing mode.
      ]

      frames = run(start, input, {RunAttemptWorkflow, :run, 2}, replay)

      # The drain emits one ClearStateCommand per nudge:* key. For our
      # single-key seed, expect exactly one — keyed on the seeded id.
      assert Enum.any?(frames, fn
               %Pb.ClearStateCommandMessage{key: ^nudge_key} -> true
               _ -> false
             end)

      # The prompt-render ctx.run runs for real — it actually invokes
      # Symphony.Core.Prompt + prepend_operator_nudges. Inspect the
      # ProposeRunCompletionMessage value to confirm the operator
      # interjection landed in front of the rendered template.
      propose =
        Enum.find(frames, fn
          %Pb.ProposeRunCompletionMessage{result_completion_id: 4} -> true
          _ -> false
        end)

      # ProposeRunCompletionMessage's `:value` variant carries the
      # raw bytes directly, not wrapped in a `Pb.Value`.
      assert %Pb.ProposeRunCompletionMessage{result: {:value, prompted_bytes}} = propose

      prompted = Jason.decode!(prompted_bytes)
      assert prompted =~ "Operator interjection"
      assert prompted =~ "be careful with the auth flow"
      # The original template result follows the divider.
      assert prompted =~ "Issue: SYM-1"

      # Handler suspends rather than reaching OutputCommand because
      # the replay was deliberately cut short.
      assert Enum.any?(frames, &match?(%Pb.SuspensionMessage{}, &1))
    end

    test "nudge_now redirect: turn 1 abandoned, loop continues to turn 2 → ended_by=max_turns" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      parsed_workflow_max2 =
        put_in(@parsed_workflow, ["config", "agent", "max_turns"], 2)

      replay = [
        # Setup
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(parsed_workflow_max2)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        },
        # --- Turn 1: nudge_now wins ---
        %Pb.RunCommandMessage{result_completion_id: 4},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 4,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 5,
          result_completion_id: 6
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 5,
          invocation_id: "inv_turn_1"
        },
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 7},
        # Awakeable for nudge_now (signal_id=17, the first allocated by
        # this invocation) is completed with the redirect sentinel.
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 17},
          result: {:value, %Pb.Value{content: Jason.encode!("nudge_now_redirect")}}
        },
        # Redirect branch: kill port (ctx.run cid 8), clear invocation
        # id, then continue the loop with a fresh fetch_issue (cid 9).
        %Pb.RunCommandMessage{result_completion_id: 8},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 8,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        },
        %Pb.ClearStateCommandMessage{key: "current_turn_invocation_id"},
        %Pb.RunCommandMessage{result_completion_id: 9},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 9,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        # --- Turn 2: completes normally ---
        %Pb.RunCommandMessage{result_completion_id: 10},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 10,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 11,
          result_completion_id: 12
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 11,
          invocation_id: "inv_turn_2"
        },
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 13},
        %Pb.CallCompletionNotificationMessage{
          completion_id: 12,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"text" => @turn_text})}}
        },
        %Pb.ClearStateCommandMessage{key: "current_turn_invocation_id"},
        %Pb.RunCommandMessage{result_completion_id: 14},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 14,
          result: {:value, %Pb.Value{content: Jason.encode!(@comment_id)}}
        },
        %Pb.SetStateCommandMessage{key: "conversation", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "turn_count", value: %Pb.Value{content: ""}},
        %Pb.SetStateCommandMessage{key: "last_comment_id", value: %Pb.Value{content: ""}},
        # Halt at turn_n=2 == max_turns=2; post-loop Manager.stop_session.
        %Pb.RunCommandMessage{result_completion_id: 15},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 15,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2},
                 replay
               )

      assert Jason.decode!(out) == %{
               "ok" => true,
               "identifier" => "SYM-1",
               "attempt_n" => 1,
               "issue_id" => "uuid-issue-1",
               "turns" => 2,
               "ended_by" => "max_turns",
               "workflow_content_hash" => "abc123"
             }
    end

    test "stall: timer wins → terminal codex_turn_stall" do
      input = %{
        "identifier" => "SYM-1",
        "attempt_n" => 1,
        "workflow_path" => "/dev/null/not-actually-read",
        "workspace_root" => "/tmp/symphony-restate-test-runs"
      }

      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(@parsed_workflow)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workflow_content_hash",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 2},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(@issue_map)}}
        },
        %Pb.RunCommandMessage{result_completion_id: 3},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 3,
          result: {:value, %Pb.Value{content: Jason.encode!(@workspace_path)}}
        },
        %Pb.SetStateCommandMessage{
          key: "workspace_path",
          value: %Pb.Value{content: ""}
        },
        %Pb.RunCommandMessage{result_completion_id: 4},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 4,
          result: {:value, %Pb.Value{content: Jason.encode!(@rendered_prompt)}}
        },
        %Pb.CallCommandMessage{
          service_name: "CodexTurnService",
          handler_name: "run",
          key: "",
          invocation_id_notification_idx: 5,
          result_completion_id: 6
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 5,
          invocation_id: @turn_invocation_id
        },
        %Pb.SetStateCommandMessage{
          key: "current_turn_invocation_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SetStateCommandMessage{
          key: "current_nudge_now_awakeable_id",
          value: %Pb.Value{content: ""}
        },
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 7},
        # Stall fires first: provide the SleepCompletionNotification but
        # NOT the CallCompletionNotification. Awaitable.any returns the
        # timer branch (idx 1).
        %Pb.SleepCompletionNotificationMessage{completion_id: 7, void: %Pb.Void{}},
        # Stall branch runs Manager.stop_session inside ctx.run (cid 8).
        %Pb.RunCommandMessage{result_completion_id: 8},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 8,
          result: {:value, %Pb.Value{content: Jason.encode!("ok")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{key: "SYM-1::a1"},
                 input,
                 {RunAttemptWorkflow, :run, 2},
                 replay
               )

      assert msg =~ "codex_turn_stall"
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
