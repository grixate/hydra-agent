Logger.configure(level: :warning)

if Mix.env() == :prod and System.get_env("HYDRA_ALLOW_PRODUCTION_BENCHMARK") != "1" do
  raise "refusing to create temporary benchmark data in production without HYDRA_ALLOW_PRODUCTION_BENCHMARK=1"
end

alias HydraAgent.Repo
alias HydraAgent.Runtime.Workspace
alias HydraAgent.Simulations.{Blueprints, SimulationRunRecord}

defmodule HydraAgent.QuickEngineBenchmark do
  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Simulations
  alias HydraAgent.Simulations.Engine
  alias HydraAgent.Simulations.Workers.QuickRunWorker

  @population_size 10_000
  @rounds 20
  @samples 3

  def run(workspace, blueprint) do
    {:ok, simulation} =
      Simulations.create_simulation(workspace, nil, %{
        "question" =>
          "How might participants respond to a bounded operational change over twenty rounds?",
        "blueprint_id" => blueprint.id,
        "locale" => "en",
        "execution_mode" => "quick",
        "population_size" => Integer.to_string(@population_size),
        "horizon" => "#{@rounds} rounds",
        "inputs" => %{}
      })

    :ok = Oban.pause_queue(queue: :simulations)

    samples =
      try do
        Enum.map(1..@samples, fn sample ->
          {:ok, record} = Simulations.create_quick_run(simulation, nil)
          baseline = :erlang.memory(:total)
          task = Task.async(fn -> Engine.execute(record.id) end)
          {result, peak} = await(task, baseline)
          {:ok, completed} = result
          cancel_job(record.id)

          %{
            "sample" => sample,
            "duration_ms" => duration_ms(completed),
            "peak_application_bytes" => peak,
            "peak_delta_bytes" => max(peak - baseline, 0),
            "result_hash" => completed.result_hash,
            "final_state_hash" => completed.final_state_hash,
            "model_calls" => completed.model_call_count,
            "event_count" => event_count(completed.run_id),
            "snapshot_count" => snapshot_count(completed.id),
            "snapshot_bytes" => snapshot_bytes(completed.id)
          }
        end)
      after
        :ok = Oban.resume_queue(queue: :simulations)
      end

    summarize(samples, simulation.active_script.content_hash)
  end

  def cleanup(workspace) do
    record_ids =
      SimulationRunRecord
      |> where([record], record.workspace_id == ^workspace.id)
      |> select([record], record.id)
      |> Repo.all()

    worker = to_string(QuickRunWorker)

    Oban.Job
    |> where([job], job.worker == ^worker)
    |> Repo.all()
    |> Enum.filter(&(get_in(&1.args, ["simulation_run_record_id"]) in record_ids))
    |> Enum.each(&Repo.delete!/1)

    SimulationRunRecord
    |> where([record], record.id in ^record_ids)
    |> Repo.delete_all()

    Repo.delete!(workspace)
  end

  defp await(task, peak) do
    case Task.yield(task, 25) do
      nil -> await(task, max(peak, :erlang.memory(:total)))
      {:ok, result} -> {result, max(peak, :erlang.memory(:total))}
      {:exit, reason} -> exit(reason)
    end
  end

  defp duration_ms(record),
    do: DateTime.diff(record.completed_at, record.started_at, :millisecond)

  defp event_count(run_id) do
    HydraAgent.Runtime.RunEvent
    |> where([event], event.run_id == ^run_id and not is_nil(event.sequence))
    |> Repo.aggregate(:count)
  end

  defp snapshot_count(record_id) do
    HydraAgent.Simulations.RunSnapshot
    |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
    |> Repo.aggregate(:count)
  end

  defp snapshot_bytes(record_id) do
    HydraAgent.Simulations.RunSnapshot
    |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
    |> select([snapshot], sum(fragment("pg_column_size(?)", snapshot.payload)))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp cancel_job(record_id) do
    worker = to_string(QuickRunWorker)

    Oban.Job
    |> where([job], job.worker == ^worker)
    |> Repo.all()
    |> Enum.filter(&(get_in(&1.args, ["simulation_run_record_id"]) == record_id))
    |> Enum.each(&Oban.cancel_job/1)
  end

  defp summarize(samples, script_hash) do
    durations = samples |> Enum.map(& &1["duration_ms"]) |> Enum.sort()
    peaks = Enum.map(samples, & &1["peak_application_bytes"])
    hashes = samples |> Enum.map(& &1["result_hash"]) |> Enum.uniq()

    %{
      "benchmark" => "Hydra Quick engine",
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "engine_version" => SimulationRunRecord.engine_version(),
      "population_size" => @population_size,
      "rounds" => @rounds,
      "samples" => @samples,
      "provider_calls_during_simulation" => 0,
      "result_hashes_identical" => length(hashes) == 1,
      "result_hash" => List.first(hashes),
      "script_hash" => script_hash,
      "duration_ms" => %{
        "minimum" => Enum.min(durations),
        "median" => Enum.at(durations, div(length(durations), 2)),
        "observed_p95_proxy" => Enum.max(durations)
      },
      "peak_application_bytes" => Enum.max(peaks),
      "target_checks" => %{
        "observed_p95_proxy_under_60_seconds" => Enum.max(durations) < 60_000,
        "peak_application_memory_under_2_gib" => Enum.max(peaks) < 2 * 1024 * 1024 * 1024,
        "exact_replay_hash_equality" => length(hashes) == 1,
        "zero_simulation_model_calls" => Enum.all?(samples, &(&1["model_calls"] == 0))
      },
      "environment" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "schedulers_online" => System.schedulers_online(),
        "operating_system" => :os.type() |> inspect()
      },
      "notes" => [
        "Three local observations; maximum duration is recorded as an initial p95 proxy, not a public performance claim.",
        "Duration includes full population compilation, all atomic round commits, event batches, and one checksummed snapshot per round.",
        "Peak memory is whole-application BEAM memory sampled every 25 ms."
      ],
      "runs" => samples
    }
  end
end

slug = "quick-benchmark-#{System.unique_integer([:positive])}"

workspace =
  %Workspace{}
  |> Workspace.changeset(%{
    name: "Quick Engine Benchmark",
    slug: slug,
    status: "active",
    settings: %{}
  })
  |> Repo.insert!()

[general | _rest] = Blueprints.ensure_builtins!()

try do
  workspace
  |> HydraAgent.QuickEngineBenchmark.run(general)
  |> Jason.encode!(pretty: true)
  |> IO.puts()
after
  HydraAgent.QuickEngineBenchmark.cleanup(workspace)
end
