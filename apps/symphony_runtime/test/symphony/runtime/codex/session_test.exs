defmodule Symphony.Runtime.Codex.SessionTest do
  use ExUnit.Case, async: true

  alias Symphony.Runtime.Codex.Session

  describe "format_with_preamble/2 (cold-path conversation seeding)" do
    test "returns prompt unchanged when no missing turns" do
      assert Session.format_with_preamble([], "do the thing") == "do the thing"
    end

    test "single missing turn: prepends preamble + transcript + divider" do
      missing = [%{turn: 1, prompt: "operator said X", response: "agent did Y"}]

      out = Session.format_with_preamble(missing, "now do Z")

      assert out =~ "Continuing a prior conversation"
      assert out =~ "Prior turn 1 — operator input:\noperator said X"
      assert out =~ "Prior turn 1 — your response:\nagent did Y"
      assert out =~ "Now respond to this turn:"
      assert out =~ "now do Z"
    end

    test "multiple missing turns: emitted in input order" do
      missing = [
        %{turn: 1, prompt: "P1", response: "R1"},
        %{turn: 2, prompt: "P2", response: "R2"},
        %{turn: 3, prompt: "P3", response: "R3"}
      ]

      out = Session.format_with_preamble(missing, "P4")

      # Order: turn 1 appears before turn 2 before turn 3.
      idx1 = :binary.match(out, "Prior turn 1") |> elem(0)
      idx2 = :binary.match(out, "Prior turn 2") |> elem(0)
      idx3 = :binary.match(out, "Prior turn 3") |> elem(0)
      idx_divider = :binary.match(out, "---") |> elem(0)
      idx_prompt = :binary.match(out, "P4") |> elem(0)

      assert idx1 < idx2
      assert idx2 < idx3
      assert idx3 < idx_divider
      assert idx_divider < idx_prompt
    end

    test "preamble explains the cross-node failover scenario" do
      out =
        Session.format_with_preamble(
          [%{turn: 1, prompt: "p", response: "r"}],
          "next"
        )

      # The preamble's content is part of the contract with codex —
      # it's the cue that tells the model "rebuild context from this
      # transcript, the live thread is gone." Don't change this
      # without updating the test (and probably re-evaluating
      # cold-path behavior).
      assert out =~ "resumed on a different"
      assert out =~ "BEAM node"
    end

    test "trims trailing whitespace from the heredoc template" do
      out =
        Session.format_with_preamble(
          [%{turn: 1, prompt: "p", response: "r"}],
          "p2"
        )

      refute String.match?(out, ~r/\s\z/)
    end

    test "transcript includes both operator input and agent response per turn" do
      missing = [
        %{turn: 7, prompt: "very specific operator text", response: "very specific agent text"}
      ]

      out = Session.format_with_preamble(missing, "next")

      assert out =~ "operator input:\nvery specific operator text"
      assert out =~ "your response:\nvery specific agent text"
    end
  end
end
