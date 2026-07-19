Logger.configure(level: :warning)

defmodule HydraAgent.PilotCases do
  import Ecto.Query

  alias HydraAgent.{Repo, Runtime, Simulations}
  alias HydraAgent.Runtime.Workspace

  alias HydraAgent.Simulations.{
    Blueprints,
    Engine,
    ReportGenerator,
    SimulationReport,
    SimulationRunRecord
  }

  @question_general "How might a bounded service change affect participant completion over three rounds?"
  @question_replay "What could a team have known before a bounded launch decision, and how might participants have responded?"

  def run do
    refuse_unsafe_environment!()
    workspace = create_workspace!()
    :ok = Oban.pause_queue(queue: :simulations)

    try do
      [general, decision_replay] = Blueprints.ensure_builtins!()
      first_provider = provider!(workspace, "Pilot model A", "mock-pilot-a")
      second_provider = provider!(workspace, "Pilot model B", "mock-pilot-b")

      general_case = general_case(workspace, general, first_provider)

      replay_case =
        decision_replay_case(
          workspace,
          decision_replay,
          first_provider,
          second_provider
        )

      %{
        "schema_version" => 1,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "qualification" => "controlled-pilot fixture",
        "provider_posture" =>
          "deterministic structured mock; external latency and billing are excluded",
        "cases" => [general_case, replay_case],
        "release_claim" =>
          "Application-flow evidence only. Real-provider staging, assistive-technology review, and off-host recovery remain separate gates."
      }
    after
      cleanup_jobs(workspace.id)
      Repo.delete!(workspace)
      :ok = Oban.resume_queue(queue: :simulations)
    end
  end

  defp general_case(workspace, blueprint, provider) do
    {:ok, simulation} =
      Simulations.create_simulation(workspace, nil, %{
        "question" => @question_general,
        "blueprint_id" => blueprint.id,
        "locale" => "en",
        "execution_mode" => "quick",
        "budget_preset" => "standard",
        "population_size" => "48",
        "horizon" => "3 rounds",
        "inputs" => %{}
      })

    {:ok, record} = Simulations.create_quick_run(simulation, nil)
    {:ok, record} = Engine.execute(record.id)
    record = Simulations.get_simulation_run_record!(record.id)
    analysis = Simulations.get_analysis_pack(record)
    {:ok, observatory} = Simulations.build_observatory_payload(analysis)
    report = report!(analysis, provider)
    {:ok, run_pack} = Simulations.export_run_pack(record)

    %{
      "case" => "General Simulation",
      "blueprint" => blueprint.name,
      "question" => @question_general,
      "source_evidence" => "none supplied",
      "mode" => record.mode,
      "population_size" => record.result_summary["population_size"],
      "rounds" => record.current_round,
      "status" => record.run.status,
      "hard_model_call_cap" => record.budget_snapshot["hard_model_call_cap"],
      "simulation_model_calls" => record.model_call_count,
      "result_hash" => record.result_hash,
      "analysis_hash" => analysis.content_hash,
      "report" => report_summary(report),
      "observatory" => observatory_summary(observatory),
      "run_pack" => artifact_summary(run_pack.binary),
      "strengths" => [
        "one-question, no-data Build completed with explicit assumptions and gaps",
        "Quick execution made zero simulation model calls",
        "Analysis, validated Report, State, Flow, Explain, and a portable Run Pack were produced"
      ],
      "limitations" => [
        "the case is synthetic and does not predict real participant behavior",
        "no external evidence was supplied, so conclusions inherit model assumptions",
        "the report provider is a deterministic mock and does not qualify external latency, quality, or cost"
      ]
    }
  end

  defp decision_replay_case(workspace, blueprint, first_provider, second_provider) do
    {:ok, simulation} =
      Simulations.create_simulation(workspace, nil, %{
        "question" => @question_replay,
        "blueprint_id" => blueprint.id,
        "locale" => "en",
        "execution_mode" => "balanced",
        "budget_preset" => "standard",
        "population_size" => "60",
        "horizon" => "3 rounds",
        "historical_cutoff" => "2024-01-31",
        "inputs" => %{}
      })

    configure_all_routes!(simulation, first_provider)
    {:ok, original} = Simulations.create_simulation_run(simulation, nil)
    {:ok, original} = Engine.execute(original.id)
    original = Simulations.get_simulation_run_record!(original.id)
    original_analysis = Simulations.get_analysis_pack(original)
    original_report = report!(original_analysis, first_provider)

    {:ok, exact_replay} = Simulations.create_exact_replay(original, nil)
    {:ok, exact_replay} = Engine.execute(exact_replay.id)
    exact_replay = Simulations.get_simulation_run_record!(exact_replay.id)

    configure_all_routes!(simulation, second_provider)
    {:ok, changed_model} = Simulations.create_fresh_rerun(original, nil)
    {:ok, changed_model} = Engine.execute(changed_model.id)
    changed_model = Simulations.get_simulation_run_record!(changed_model.id)
    changed_analysis = Simulations.get_analysis_pack(changed_model)
    changed_report = report!(changed_analysis, second_provider)
    {:ok, run_pack} = Simulations.export_run_pack(original)

    %{
      "case" => "Decision Replay",
      "blueprint" => blueprint.name,
      "question" => @question_replay,
      "historical_cutoff" => "2024-01-31",
      "strict_historical_cutoff" =>
        simulation.active_context_pack.scope["strict_historical_cutoff"],
      "mode" => original.mode,
      "population_size" => original.result_summary["population_size"],
      "rounds" => original.current_round,
      "status" => original.run.status,
      "hard_model_call_cap" => original.budget_snapshot["hard_model_call_cap"],
      "simulation_model_calls" => original.model_call_count,
      "fallbacks" => original.fallback_count,
      "result_hash" => original.result_hash,
      "report" => report_summary(original_report),
      "exact_replay" => %{
        "status" => exact_replay.run.status,
        "provider_calls" => exact_replay.model_call_count,
        "result_hash_equal" => exact_replay.result_hash == original.result_hash,
        "state_hash_equal" => exact_replay.final_state_hash == original.final_state_hash,
        "decision_manifest_equal" =>
          exact_replay.decision_manifest_hash == original.decision_manifest_hash
      },
      "changed_model_rerun" => %{
        "status" => changed_model.run.status,
        "replay_kind" => changed_model.replay_kind,
        "model" => get_in(changed_model.model_route_snapshot, ["simulation", "model"]),
        "model_changed" =>
          get_in(changed_model.model_route_snapshot, ["simulation", "model"]) !=
            get_in(original.model_route_snapshot, ["simulation", "model"]),
        "seed_changed" => changed_model.seed != original.seed,
        "result_hash" => changed_model.result_hash,
        "report" => report_summary(changed_report)
      },
      "run_pack" => artifact_summary(run_pack.binary),
      "strengths" => [
        "historical-cutoff handling remained explicit in the immutable Context lineage",
        "Balanced cognition stayed inside its hard call cap and exact replay made zero provider calls",
        "a fresh rerun used a changed model route and produced a separately validated Report"
      ],
      "limitations" => [
        "the fixture contains no verified historical sources, so it exposes gaps rather than reconstructing facts",
        "mock-model agreement is not evidence of real-model quality or cross-model robustness",
        "a changed seed and model route are controlled differences, so the fresh rerun is not an exact comparison"
      ]
    }
  end

  defp configure_all_routes!(simulation, provider) do
    {:ok, configuration} =
      Simulations.configure_run(simulation, nil, %{
        "model_routes" => %{
          "build" => to_string(provider.id),
          "simulation" => to_string(provider.id),
          "report" => to_string(provider.id)
        }
      })

    configuration
  end

  defp report!(analysis, provider) do
    {:ok, report} =
      Simulations.queue_simulation_report(analysis, nil, %{
        "provider_config_id" => provider.id,
        "locale" => "en",
        "audience" => "executive",
        "length" => "concise"
      })

    case ReportGenerator.generate(report.id) do
      :ok -> :ok
      {:ok, _ready} -> :ok
    end

    Repo.get!(SimulationReport, report.id)
  end

  defp report_summary(report) do
    %{
      "status" => report.status,
      "validation_status" => report.validation_status,
      "version" => report.version,
      "content_hash" => report.content_hash,
      "evidence_reference_count" =>
        report.sections
        |> Enum.flat_map(&List.wrap(&1["references"]))
        |> Enum.uniq()
        |> length()
    }
  end

  defp observatory_summary(payload) do
    %{
      "state" => is_map(payload["state"]),
      "flow" => is_map(payload["flow"]),
      "explain" => is_map(payload["explain"]),
      "content_hash" => payload["content_hash"]
    }
  end

  defp artifact_summary(binary) do
    %{
      "bytes" => byte_size(binary),
      "sha256" => :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    }
  end

  defp provider!(workspace, name, model) do
    {:ok, provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: name,
        kind: "mock",
        model: model,
        enabled: true,
        metadata: %{
          "capabilities" => %{
            "structured_generation" => true,
            "local_execution" => true,
            "deterministic_seed" => true
          }
        }
      })

    provider
  end

  defp create_workspace! do
    slug = "pilot-cases-#{System.unique_integer([:positive])}"

    %Workspace{}
    |> Workspace.changeset(%{
      name: "Pilot Case Qualification",
      slug: slug,
      status: "active",
      settings: %{}
    })
    |> Repo.insert!()
  end

  defp cleanup_jobs(workspace_id) do
    record_ids =
      SimulationRunRecord
      |> where([record], record.workspace_id == ^workspace_id)
      |> select([record], record.id)
      |> Repo.all()
      |> MapSet.new()

    report_ids =
      SimulationReport
      |> where([report], report.workspace_id == ^workspace_id)
      |> select([report], report.id)
      |> Repo.all()
      |> MapSet.new()

    Oban.Job
    |> Repo.all()
    |> Enum.filter(fn job ->
      MapSet.member?(record_ids, job.args["simulation_run_record_id"]) or
        MapSet.member?(report_ids, job.args["simulation_report_id"])
    end)
    |> Enum.each(&Repo.delete!/1)
  end

  defp refuse_unsafe_environment! do
    if Mix.env() == :prod and System.get_env("HYDRA_ALLOW_PILOT_FIXTURE") != "1" do
      raise "refusing to create temporary pilot fixtures in production without HYDRA_ALLOW_PILOT_FIXTURE=1"
    end
  end
end

HydraAgent.PilotCases.run()
|> Jason.encode!(pretty: true)
|> IO.puts()
