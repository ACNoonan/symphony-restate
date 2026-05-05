defmodule Symphony.Core.WorkflowTest do
  use ExUnit.Case, async: true

  alias Symphony.Core.Workflow

  describe "parse/1" do
    test "parses front matter + prompt body" do
      content = """
      ---
      tracker:
        kind: linear
        project_slug: foo
      polling:
        interval_ms: 30000
      ---
      Hello {{ issue.identifier }}.
      """

      assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.parse(content)
      assert config["tracker"]["kind"] == "linear"
      assert config["tracker"]["project_slug"] == "foo"
      assert config["polling"]["interval_ms"] == 30_000
      assert prompt == "Hello {{ issue.identifier }}."
    end

    test "treats absent front matter as empty config" do
      assert {:ok, %{config: %{}, prompt_template: "just a prompt"}} =
               Workflow.parse("just a prompt")
    end

    test "rejects non-map YAML at front matter root" do
      content = """
      ---
      - one
      - two
      ---
      body
      """

      assert {:error, :workflow_front_matter_not_a_map} = Workflow.parse(content)
    end

    test "treats missing closing fence as empty prompt" do
      content = """
      ---
      tracker:
        kind: linear
      """

      assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt_template: ""}} =
               Workflow.parse(content)
    end

    test "trims prompt body" do
      content = """
      ---
      polling:
        interval_ms: 1000
      ---


      hello


      """

      assert {:ok, %{prompt_template: "hello"}} = Workflow.parse(content)
    end
  end

  describe "load/1" do
    test "returns missing_workflow_file for unknown path" do
      assert {:error, {:missing_workflow_file, "/nope/nope.md", :enoent}} =
               Workflow.load("/nope/nope.md")
    end

    test "loads a real file" do
      path = Path.join(System.tmp_dir!(), "wf-#{System.unique_integer([:positive])}.md")
      File.write!(path, "---\npolling:\n  interval_ms: 5000\n---\nhi")

      try do
        assert {:ok, %{prompt_template: "hi"}} = Workflow.load(path)
      after
        File.rm(path)
      end
    end
  end
end
