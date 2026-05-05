defmodule Symphony.Core.Workflow do
  @moduledoc """
  WORKFLOW.md loader / parser per `SPEC.md` §5.

  Pure module: takes a path or a content string and returns the parsed
  `{config, prompt_template}`. No file-watch, no hot-reload — the
  Restate-native architecture (see `docs/architecture.md`) treats
  WORKFLOW.md as a deployment artifact, not a live-reload source.
  Callers in `:symphony_runtime` invoke `load/1` from inside `ctx.run`
  so the file read becomes a journaled side-effect.

  External contract is preserved verbatim: drop in any upstream
  Symphony WORKFLOW.md and `parse/1` returns the same shape the
  upstream `SymphonyElixir.Workflow` does.
  """

  @type t :: %{config: map(), prompt_template: String.t()}

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    {front_lines, prompt_lines} = split_front_matter(content)

    case decode_front_matter(front_lines) do
      {:ok, config} ->
        prompt = prompt_lines |> Enum.join("\n") |> String.trim()
        {:ok, %{config: config, prompt_template: prompt}}

      {:error, :workflow_front_matter_not_a_map} = err ->
        err

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp decode_front_matter(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
