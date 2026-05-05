defmodule Symphony.Core.PromptTest do
  use ExUnit.Case, async: true

  alias Symphony.Core.{Issue, Prompt}

  describe "render/2" do
    test "renders a basic template against an Issue struct" do
      issue = %Issue{
        identifier: "SYM-1",
        title: "Wire up first turn",
        description: "Make the demo go.",
        state: "Todo",
        labels: ["foo", "bar"]
      }

      template = """
      Issue {{ issue.identifier }}: {{ issue.title }}
      State: {{ issue.state }}
      """

      assert {:ok, output} = Prompt.render(template, %{issue: issue})
      assert output =~ "Issue SYM-1: Wire up first turn"
      assert output =~ "State: Todo"
    end

    test "exposes attempt as optional variable" do
      issue = %Issue{identifier: "SYM-2"}

      template = "Attempt {{ attempt | default: 'first' }} on {{ issue.identifier }}"
      assert {:ok, output} = Prompt.render(template, %{issue: issue, attempt: 3})
      assert output == "Attempt 3 on SYM-2"

      assert {:ok, output} = Prompt.render(template, %{issue: issue})
      assert output == "Attempt first on SYM-2"
    end

    test "fails on unknown variables (strict mode)" do
      issue = %Issue{identifier: "SYM-3"}
      template = "{{ issue.identifier }} {{ totally_unknown }}"

      assert {:error, {:template_render_error, _}} = Prompt.render(template, %{issue: issue})
    end

    test "fails on parse errors" do
      issue = %Issue{identifier: "SYM-4"}
      template = "{% if x %} unclosed"

      assert {:error, {:template_parse_error, _}} = Prompt.render(template, %{issue: issue})
    end
  end
end
