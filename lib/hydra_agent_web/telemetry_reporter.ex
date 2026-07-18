defmodule HydraAgentWeb.TelemetryReporter do
  @moduledoc "Bounded in-process telemetry aggregates with an OpenMetrics export."
  use GenServer

  @table __MODULE__
  @events [
    [:phoenix, :endpoint, :stop],
    [:hydra_agent, :repo, :query],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def snapshot do
    events =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {{name, labels}, _stored_labels, count, total_native} ->
        %{
          name: name,
          labels: Map.new(labels),
          count: count,
          total_ms: System.convert_time_unit(total_native, :native, :millisecond)
        }
      end)
      |> Enum.sort_by(&{&1.name, &1.labels})

    %{events: events, runtime: runtime_snapshot()}
  end

  def openmetrics do
    snapshot = snapshot()

    event_lines =
      Enum.flat_map(snapshot.events, fn event ->
        labels = format_labels(event.labels)

        [
          "hydra_#{event.name}_total#{labels} #{event.count}",
          "hydra_#{event.name}_duration_milliseconds_sum#{labels} #{event.total_ms}",
          "hydra_#{event.name}_duration_milliseconds_count#{labels} #{event.count}"
        ]
      end)

    runtime_lines =
      Enum.map(snapshot.runtime, fn {name, value} -> "hydra_beam_#{name} #{value}" end)

    Enum.join(
      [
        "# HELP hydra_up Whether this Hydra instance can export telemetry.",
        "# TYPE hydra_up gauge",
        "hydra_up 1",
        "# TYPE hydra_http_requests_total counter",
        "# TYPE hydra_repo_queries_total counter",
        "# TYPE hydra_oban_jobs_total counter"
        | event_lines ++ runtime_lines ++ ["# EOF"]
      ],
      "\n"
    ) <> "\n"
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :telemetry.attach_many("hydra-telemetry-reporter", @events, &__MODULE__.handle_event/4, nil)
    {:ok, %{}}
  end

  def handle_event(event, measurements, metadata, _config) do
    {name, labels} = event_identity(event, metadata)
    duration = measurements[:duration] || measurements[:total_time] || 0
    key = {name, labels}

    :ets.update_counter(@table, key, [{3, 1}, {4, duration}], {key, labels, 0, 0})
    :ok
  end

  defp event_identity([:phoenix, :endpoint, :stop], metadata) do
    status = metadata |> Map.get(:conn, %{}) |> Map.get(:status)
    {"http_requests", [{"status_class", status_class(status)}]}
  end

  defp event_identity([:hydra_agent, :repo, :query], _metadata), do: {"repo_queries", []}

  defp event_identity([:oban, :job, outcome], metadata) do
    queue = metadata |> Map.get(:job, %{}) |> Map.get(:queue, "unknown") |> bounded_label()
    {"oban_jobs", [{"outcome", Atom.to_string(outcome)}, {"queue", queue}]}
  end

  defp status_class(status) when is_integer(status), do: "#{div(status, 100)}xx"
  defp status_class(_status), do: "unknown"

  defp bounded_label(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_.-]/u, "_")
    |> String.slice(0, 48)
  end

  defp runtime_snapshot do
    memory = :erlang.memory()

    %{
      memory_bytes: memory[:total],
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  defp format_labels(labels) when map_size(labels) == 0, do: ""

  defp format_labels(labels) do
    encoded =
      labels
      |> Enum.sort()
      |> Enum.map_join(",", fn {name, value} ->
        escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        "#{name}=\"#{escaped}\""
      end)

    "{#{encoded}}"
  end
end
