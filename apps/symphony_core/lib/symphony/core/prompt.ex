defmodule Symphony.Core.Prompt do
  @moduledoc """
  Liquid-template rendering for WORKFLOW.md prompts per `SPEC.md` §5.4.

  Strict variables and strict filters: unknown variables / filters
  fail the render. That's the spec contract — silent fallbacks would
  mask bugs in the per-repo workflow file.

  Pure. Safe to call from inside `ctx.run`.
  """

  alias Symphony.Core.Issue

  @render_opts [strict_variables: true, strict_filters: true]

  @type vars :: %{
          required(:issue) => Issue.t() | map(),
          optional(:attempt) => integer() | nil
        }

  @spec render(String.t(), vars()) :: {:ok, String.t()} | {:error, term()}
  def render(template, %{issue: issue} = vars) when is_binary(template) do
    with {:ok, parsed} <- safe_parse(template) do
      try do
        rendered =
          parsed
          |> Solid.render!(
            %{
              "issue" => to_solid(issue),
              "attempt" => Map.get(vars, :attempt)
            },
            @render_opts
          )
          |> IO.iodata_to_binary()

        {:ok, rendered}
      rescue
        e -> {:error, {:template_render_error, Exception.message(e)}}
      end
    end
  end

  defp safe_parse(template) do
    {:ok, Solid.parse!(template)}
  rescue
    e -> {:error, {:template_parse_error, Exception.message(e)}}
  end

  # Solid expects string keys all the way down. Coerce structs and
  # atom-keyed maps recursively.
  defp to_solid(%_{} = struct), do: struct |> Map.from_struct() |> to_solid()

  defp to_solid(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_solid(v)} end)
  end

  defp to_solid(list) when is_list(list), do: Enum.map(list, &to_solid/1)
  defp to_solid(other), do: other
end
