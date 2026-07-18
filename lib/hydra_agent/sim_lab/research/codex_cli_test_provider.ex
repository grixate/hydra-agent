defmodule HydraAgent.SimLab.Research.CodexCliTestProvider do
  @moduledoc """
  Local-only hypothesis provider backed by an authenticated Codex CLI.

  This adapter exists to exercise the research pipeline before a production
  model provider is configured. It receives only planner-generated safe
  queries, invokes Codex once for the complete lane batch, and converts the
  strictly validated response into low-confidence assumptions. It never marks
  generated text as external research and is disabled in production.
  """

  @behaviour HydraAgent.SimLab.Research.WebSearchProvider

  @default_timeout_ms 120_000
  @max_title_bytes 200
  @max_snippet_bytes 2_000
  @max_process_output_bytes 1_000_000

  @impl true
  def search(lane) do
    with {:ok, results_by_lane} <- search_many([lane]) do
      {:ok, Map.get(results_by_lane, lane.lane, [])}
    end
  end

  @impl true
  def search_many(lanes) when is_list(lanes) do
    with :ok <- ensure_enabled(),
         :ok <- validate_lanes(lanes),
         {:ok, output} <- invoke(prompt(lanes)),
         {:ok, candidates} <- decode_candidates(output),
         {:ok, results} <- normalize_candidates(candidates, lanes) do
      {:ok, Enum.group_by(results, & &1.lane, &Map.delete(&1, :lane))}
    end
  end

  def enabled? do
    config = config()

    config[:enabled?] == true and
      Application.get_env(:hydra_agent, :environment, :prod) != :prod and
      System.get_env("HYDRA_SIM_CODEX_CLI_TESTING") == "1"
  end

  defp ensure_enabled, do: if(enabled?(), do: :ok, else: {:error, :codex_cli_test_disabled})

  defp validate_lanes([]), do: {:error, :no_research_lanes}

  defp validate_lanes(lanes) do
    if Enum.all?(lanes, &valid_lane?/1),
      do: :ok,
      else: {:error, :invalid_research_lane}
  end

  defp valid_lane?(lane) do
    is_binary(Map.get(lane, :lane)) and
      is_binary(Map.get(lane, :safe_query)) and
      Map.get(lane, :safe_query) != "" and
      is_binary(Map.get(lane, :purpose))
  end

  defp invoke(prompt) do
    case config()[:runner] do
      runner when is_function(runner, 1) -> normalize_runner_result(runner.(prompt))
      _ -> invoke_cli(prompt)
    end
  rescue
    error -> {:error, {:codex_cli_runner_failed, Exception.message(error)}}
  end

  defp invoke_cli(prompt) do
    executable = config()[:executable] || "codex"

    case System.find_executable(executable) do
      nil ->
        {:error, :codex_cli_not_found}

      path ->
        args = [
          "exec",
          "--ignore-user-config",
          "--skip-git-repo-check",
          "--sandbox",
          "read-only",
          "--ephemeral",
          "--ignore-rules",
          "--color",
          "never",
          "--json",
          prompt
        ]

        timeout = config()[:timeout_ms] || @default_timeout_ms

        case run_port(path, args, timeout) do
          {:ok, output, 0} -> {:ok, output}
          {:ok, output, status} -> {:error, {:codex_cli_exit, status, safe_error(output)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # `:in` makes the port output-only from Hydra's perspective and gives Codex
  # an immediate stdin EOF. Without it, an interactive Phoenix terminal can
  # leave stdin open and Codex correctly waits for "additional input" forever.
  defp run_port(path, args, timeout) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :in,
          args: Enum.map(args, &String.to_charlist/1),
          cd: String.to_charlist(System.tmp_dir!()),
          env: [{~c"NO_COLOR", ~c"1"}]
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout
    collect_port(port, [], 0, deadline)
  rescue
    error -> {:error, {:codex_cli_spawn_failed, Exception.message(error)}}
  end

  defp collect_port(port, chunks, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        next_size = size + byte_size(data)

        if next_size > @max_process_output_bytes do
          close_port(port)
          {:error, :codex_cli_output_too_large}
        else
          collect_port(port, [data | chunks], next_size, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        close_port(port)
        {:error, :codex_cli_timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp normalize_runner_result({:ok, output}) when is_binary(output), do: {:ok, output}
  defp normalize_runner_result({:error, _reason} = error), do: error
  defp normalize_runner_result(output) when is_binary(output), do: {:ok, output}
  defp normalize_runner_result(_), do: {:error, :invalid_codex_cli_runner_response}

  defp prompt(lanes) do
    lane_payload =
      Enum.map(lanes, fn lane ->
        %{
          lane: lane.lane,
          purpose: lane.purpose,
          safe_query: lane.safe_query,
          region: lane.region,
          language: lane.language
        }
      end)

    """
    You are generating SYNTHETIC TEST HYPOTHESES for a research simulation pipeline.
    Do not claim that you searched the web, read a source, or verified a fact.
    Do not include URLs, citations, people, organisations, or private identifiers.
    For each input lane, return one cautious, falsifiable hypothesis that could later be researched.

    Return JSON only, with this exact shape:
    {"results":[{"lane":"input lane","title":"short hypothesis label","snippet":"one or two cautious sentences"}]}

    Keep each title under 120 characters and each snippet under 700 characters.
    Input lanes:
    #{Jason.encode!(lane_payload)}
    """
  end

  defp decode_candidates(output) do
    output
    |> json_documents()
    |> Enum.find_value({:error, :invalid_codex_cli_output}, fn document ->
      case candidates_from_document(document) do
        {:ok, candidates} -> {:ok, candidates}
        _ -> nil
      end
    end)
  end

  defp json_documents(output) do
    direct = decode_json(output)

    json_lines =
      output
      |> String.split(~r/\R/u, trim: true)
      |> Enum.flat_map(fn line ->
        case decode_json(line) do
          nil -> []
          decoded -> [decoded]
        end
      end)

    embedded =
      json_lines
      |> Enum.flat_map(&collect_text_values/1)
      |> Enum.flat_map(fn text ->
        case decode_embedded_json(text) do
          nil -> []
          decoded -> [decoded]
        end
      end)

    List.wrap(direct) ++ Enum.reverse(json_lines) ++ Enum.reverse(embedded)
  end

  defp decode_json(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_embedded_json(text) do
    text = String.trim(text)

    candidates =
      ([text] ++
         Regex.scan(~r/```(?:json)?\s*([\s\S]*?)```/iu, text, capture: :all_but_first))
      |> List.flatten()

    Enum.find_value(candidates, &decode_json/1)
  end

  defp collect_text_values(value) when is_map(value) do
    own =
      value
      |> Enum.filter(fn {key, item} ->
        to_string(key) in ["text", "content", "message", "output_text"] and is_binary(item)
      end)
      |> Enum.map(&elem(&1, 1))

    own ++ Enum.flat_map(Map.values(value), &collect_text_values/1)
  end

  defp collect_text_values(value) when is_list(value),
    do: Enum.flat_map(value, &collect_text_values/1)

  defp collect_text_values(_value), do: []

  defp candidates_from_document(%{"results" => results}) when is_list(results),
    do: {:ok, results}

  defp candidates_from_document(%{results: results}) when is_list(results), do: {:ok, results}
  defp candidates_from_document(_), do: {:error, :missing_results}

  defp normalize_candidates(candidates, lanes) do
    allowed_lanes = MapSet.new(Enum.map(lanes, & &1.lane))

    normalized = Enum.map(candidates, &normalize_candidate(&1, allowed_lanes))

    normalized_results =
      normalized
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq_by(& &1.lane)

    returned_lanes = MapSet.new(normalized_results, & &1.lane)

    cond do
      candidates == [] -> {:error, :empty_codex_cli_output}
      Enum.any?(normalized, &match?({:error, _}, &1)) -> {:error, :invalid_codex_cli_result}
      returned_lanes != allowed_lanes -> {:error, :incomplete_codex_cli_result}
      true -> {:ok, normalized_results}
    end
  end

  defp normalize_candidate(candidate, allowed_lanes) when is_map(candidate) do
    lane = field(candidate, "lane")
    title = field(candidate, "title")
    snippet = field(candidate, "snippet")

    if MapSet.member?(allowed_lanes, lane) and bounded_text?(title, @max_title_bytes) and
         bounded_text?(snippet, @max_snippet_bytes) do
      {:ok,
       %{
         lane: lane,
         title: String.trim(title),
         url: nil,
         snippet: String.trim(snippet),
         reliability: "low",
         grounding_level: "assumption",
         source_kind: "manual_note",
         provider_mode: "codex_cli_test",
         synthetic_test: true
       }}
    else
      {:error, :invalid_candidate}
    end
  end

  defp normalize_candidate(_candidate, _allowed_lanes), do: {:error, :invalid_candidate}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp bounded_text?(value, max_bytes),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= max_bytes

  defp safe_error(output) do
    output
    |> String.replace(~r/[\r\n\t]+/u, " ")
    |> String.slice(0, 300)
  end

  defp config do
    Application.get_env(:hydra_agent, :sim_lab_codex_cli, []) |> Map.new()
  end
end
