defmodule HydraAgent.Simulations.AnalysisReportTest do
  use HydraAgent.DataCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Repo, Runtime, Simulations}

  alias HydraAgent.Simulations.{
    AnalysisBuilder,
    AnalysisPack,
    Blueprints,
    ReportGenerator,
    ReportValidator,
    SimulationReport
  }

  alias HydraAgent.Simulations.Engine
  alias HydraAgent.Simulations.Workers.ReportGenerationWorker

  setup do
    workspace = workspace_fixture(%{name: "Analysis", slug: "analysis-report"})
    [general, _decision] = Blueprints.ensure_builtins!()

    assert {:ok, provider} =
             Runtime.create_provider(%{
               workspace_id: workspace.id,
               name: "Local reports",
               kind: "mock",
               model: "mock-report-v1",
               enabled: true,
               metadata: %{
                 "capabilities" => %{
                   "structured_generation" => true,
                   "local_execution" => true
                 }
               }
             })

    assert {:ok, simulation} =
             Simulations.create_simulation(workspace, nil, %{
               "question" => "How might a bounded intervention change participant behavior?",
               "blueprint_id" => general.id,
               "locale" => "en",
               "execution_mode" => "quick",
               "population_size" => "36",
               "horizon" => "3 rounds",
               "inputs" => %{}
             })

    assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
    assert {:ok, record} = Engine.execute(record.id)
    record = Simulations.get_simulation_run_record!(record.id)
    pack = Simulations.get_analysis_pack(record)

    %{
      workspace: workspace,
      general: general,
      simulation: simulation,
      record: record,
      pack: pack,
      provider: provider
    }
  end

  test "completion publishes one deterministic, bounded, reference-addressable Analysis Pack", %{
    record: record,
    pack: pack
  } do
    assert %AnalysisPack{} = pack
    assert pack.simulation_run_record_id == record.id
    assert pack.content_hash =~ ~r/^[a-f0-9]{64}$/
    assert pack.setup["result_hash"] == record.result_hash
    assert pack.metrics != []
    assert map_size(pack.reference_index) > 0
    assert Map.has_key?(pack.reference_index, "setup:run")
    assert Enum.all?(pack.metrics, &Map.has_key?(pack.reference_index, &1["ref"]))
    assert length(pack.timeline) <= 48
    assert length(pack.pivotal_events) <= 24
    assert length(pack.representative_traces) <= 32

    assert {:ok, first} = AnalysisBuilder.build(record.id)
    assert {:ok, second} = AnalysisBuilder.build(record.id)
    assert first["content_hash"] == second["content_hash"]
    assert first["content_hash"] == pack.content_hash
    assert {:ok, same_pack} = AnalysisBuilder.ensure_for_run(record)
    assert same_pack.id == pack.id

    assert_raise Postgrex.Error, ~r/simulation_analysis_packs is append-only/, fn ->
      AnalysisPack
      |> where([current], current.id == ^pack.id)
      |> Repo.update_all(set: [protocol_version: "mutated"])
    end
  end

  test "Observatory is deterministic, aggregate-first, compact, and inspectable on demand", %{
    record: record,
    pack: pack
  } do
    assert {:ok, first} = Simulations.build_observatory_payload(pack)
    assert {:ok, second} = Simulations.build_observatory_payload(pack)
    assert first == second
    assert first["protocol_version"] == "hydra-observatory/v1"
    assert first["content_hash"] =~ ~r/^[a-f0-9]{64}$/
    assert first["comparison"] == %{"status" => "none"}

    type_cohorts = Enum.filter(first["state"]["cohorts"], &(&1["kind"] == "type"))
    assert Enum.sum(Enum.map(type_cohorts, & &1["count"])) == first["run"]["population_size"]
    assert length(first["state"]["samples"]) <= 32
    assert length(first["flow"]["timeline"]) <= 48
    assert length(first["explain"]["modeled_drivers"]) <= 16
    assert Enum.all?(first["state"]["resources"], &is_number(&1["mean"]))

    encoded = Jason.encode!(first)
    refute encoded =~ ~s("agents":)
    assert byte_size(encoded) < 2_000_000
    assert encoded |> :zlib.gzip() |> byte_size() < 500_000

    sample = Enum.find(first["state"]["samples"], & &1["persona_available"])
    assert sample
    assert {:ok, detail} = Simulations.get_observatory_agent(record, sample["id"], "ru")
    assert detail["protocol_version"] == "hydra-observatory-agent/v1"
    assert detail["synthetic"]
    assert detail["agent"]["id"] == sample["id"]
    assert detail["persona"]["prose"] != ""
    assert length(detail["history"]) <= 64
    assert length(detail["relationships"]) <= 24
    assert length(detail["decisions"]) <= 32
    refute Map.has_key?(detail["agent"], "memory_seeds")

    assert {:error, :invalid_agent_id} =
             Simulations.get_observatory_agent(record, "../../not-an-agent", "en")

    assert {:error, :agent_not_found} =
             Simulations.get_observatory_agent(record, "agent-not-present", "en")
  end

  test "Observatory comparison keeps governing compatibility and replay differences explicit", %{
    record: record,
    pack: pack
  } do
    assert {:ok, replay} = Simulations.create_exact_replay(record, nil)
    assert {:ok, _completed} = Engine.execute(replay.id)
    replay = Simulations.get_simulation_run_record!(replay.id)
    replay_pack = Simulations.get_analysis_pack(replay)

    assert {:ok, comparison} = Simulations.build_observatory_payload(pack, replay_pack)
    assert comparison["comparison"]["status"] == "ready"
    assert comparison["comparison"]["directly_comparable"]
    assert comparison["comparison"]["differences"] == []

    assert Enum.any?(comparison["comparison"]["controlled_differences"], fn difference ->
             difference["field"] == "replay_kind" and
               difference["current"] == "original" and
               difference["baseline"] == "exact_replay"
           end)

    assert comparison["flow"]["baseline_timeline"] != []
    assert comparison["comparison"]["metric_deltas"] != []
  end

  test "a 5,000-agent Observatory remains below the initial-payload envelope", %{
    workspace: workspace,
    general: general
  } do
    assert {:ok, simulation} =
             Simulations.create_simulation(workspace, nil, %{
               "question" => "How does a large bounded synthetic population distribute outcomes?",
               "blueprint_id" => general.id,
               "locale" => "en",
               "execution_mode" => "quick",
               "population_size" => "5000",
               "horizon" => "3 rounds",
               "inputs" => %{}
             })

    assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
    assert {:ok, _completed} = Engine.execute(record.id)
    record = Simulations.get_simulation_run_record!(record.id)
    pack = Simulations.get_analysis_pack(record)
    assert {:ok, payload} = Simulations.build_observatory_payload(pack)

    encoded = Jason.encode!(payload)
    compressed = encoded |> :zlib.gzip() |> byte_size()

    assert payload["run"]["population_size"] == 5_000
    assert length(payload["state"]["samples"]) <= 32
    assert length(payload["state"]["cohorts"]) < 100
    refute encoded =~ ~s("agents":)
    assert compressed < 500_000
  end

  test "a valid report is generated asynchronously and can be regenerated without rerunning", %{
    record: record,
    pack: pack,
    provider: provider
  } do
    assert {:ok, queued} =
             Simulations.queue_simulation_report(pack, nil, %{
               "provider_config_id" => provider.id,
               "locale" => "en",
               "audience" => "executive",
               "length" => "concise"
             })

    assert queued.status == "queued"
    assert queued.analysis_hash == pack.content_hash
    assert queued.pricing_known
    assert queued.reserved_cost == Decimal.new(0)

    assert :ok =
             perform_job(ReportGenerationWorker, %{"simulation_report_id" => queued.id})

    first = Repo.get!(SimulationReport, queued.id)
    assert first.status == "ready"
    assert first.validation_status == "validated"
    assert length(first.sections) == 9
    assert first.actual_input_tokens == 320
    assert first.actual_output_tokens == 420
    assert first.content_hash =~ ~r/^[a-f0-9]{64}$/

    assert {:ok, regenerated} =
             Simulations.queue_simulation_report(pack, nil, %{
               "source_report_id" => first.id,
               "provider_config_id" => provider.id,
               "locale" => "ru",
               "audience" => "technical",
               "length" => "detailed"
             })

    assert regenerated.version == first.version + 1
    assert regenerated.source_report_id == first.id
    assert regenerated.locale == "ru"
    assert regenerated.simulation_run_record_id == record.id

    assert :ok =
             perform_job(ReportGenerationWorker, %{"simulation_report_id" => regenerated.id})

    second = Repo.get!(SimulationReport, regenerated.id)
    assert second.status == "ready"
    assert second.title == "Отчёт о симуляции"
    assert Repo.get!(HydraAgent.Runtime.Run, record.run_id).status == "completed"

    assert_raise Postgrex.Error, ~r/Terminal Report is immutable/, fn ->
      SimulationReport
      |> where([current], current.id == ^second.id)
      |> Repo.update_all(set: [title: "Mutated"])
    end
  end

  test "duplicate delivery never redispatches an active provider request", %{
    pack: pack,
    provider: provider
  } do
    provider
    |> Ecto.Changeset.change(
      metadata: Map.put(provider.metadata, "mock_report_response", "error")
    )
    |> Repo.update!()

    assert {:ok, queued} =
             Simulations.queue_simulation_report(pack, nil, %{
               "provider_config_id" => provider.id
             })

    running =
      queued
      |> SimulationReport.changeset(%{
        status: "running",
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

    assert :ok = ReportGenerator.generate(running.id, 1)
    assert Repo.get!(SimulationReport, running.id).status == "running"

    assert :ok = ReportGenerator.generate(running.id, 2)
    interrupted = Repo.get!(SimulationReport, running.id)
    assert interrupted.status == "failed"
    assert interrupted.failure["code"] == "interrupted_provider_request"
  end

  test "each Analysis Pack enforces its bounded report-generation allowance", %{
    pack: pack,
    provider: provider
  } do
    for expected_version <- 1..pack.report_generation_cap do
      assert {:ok, report} =
               Simulations.queue_simulation_report(pack, nil, %{
                 "provider_config_id" => provider.id
               })

      assert report.version == expected_version
    end

    assert {:error, {:report_not_queued, message}} =
             Simulations.queue_simulation_report(pack, nil, %{
               "provider_config_id" => provider.id
             })

    assert message =~ "report-generation cap exhausted"
    assert Repo.aggregate(SimulationReport, :count) == pack.report_generation_cap
  end

  test "unsupported model claims fail closed while the authoritative Run remains complete", %{
    record: record,
    pack: pack,
    provider: provider
  } do
    provider
    |> Ecto.Changeset.change(
      metadata: Map.put(provider.metadata, "mock_report_response", "invalid_number")
    )
    |> Repo.update!()

    assert {:ok, queued} =
             Simulations.queue_simulation_report(pack, nil, %{
               "provider_config_id" => provider.id
             })

    assert :ok =
             perform_job(ReportGenerationWorker, %{"simulation_report_id" => queued.id})

    failed = Repo.get!(SimulationReport, queued.id)
    assert failed.status == "failed"
    assert failed.validation_status == "rejected"
    assert Enum.any?(failed.validation_errors, &(&1["code"] == "unsupported_number"))
    assert Repo.get!(HydraAgent.Runtime.Run, record.run_id).status == "completed"
    assert Simulations.get_analysis_pack(record).content_hash == pack.content_hash
  end

  test "validator rejects unknown references, invented URLs, unsupported quotes, and unreferenced numbers",
       %{pack: pack} do
    valid = valid_payload(pack.metrics |> List.first() |> Map.fetch!("ref"))
    assert {:ok, _normalized} = ReportValidator.validate(pack, valid)

    unknown = put_in(valid, ["sections", Access.at(0), "references"], ["metric:unknown"])
    assert {:error, errors} = ReportValidator.validate(pack, unknown)
    assert Enum.any?(errors, &(&1["code"] == "unknown_reference"))

    invented_url =
      put_in(valid, ["sections", Access.at(0), "body"], "See https://invented.invalid.")

    assert {:error, errors} = ReportValidator.validate(pack, invented_url)
    assert Enum.any?(errors, &(&1["code"] == "invented_url"))

    unsupported_quote =
      put_in(valid, ["sections", Access.at(0), "body"], "An agent said “I agree”.")

    assert {:error, errors} = ReportValidator.validate(pack, unsupported_quote)
    assert Enum.any?(errors, &(&1["code"] == "unsupported_quote"))

    unreferenced_number = put_in(valid, ["summary"], "The result changed by 999999 percent.")
    assert {:error, errors} = ReportValidator.validate(pack, unreferenced_number)
    assert Enum.any?(errors, &(&1["code"] == "unreferenced_number"))
  end

  test "exports are deterministic, escaped, and retain provenance", %{
    record: record,
    pack: pack,
    provider: provider
  } do
    assert {:ok, queued} =
             Simulations.queue_simulation_report(pack, nil, %{
               "provider_config_id" => provider.id
             })

    assert :ok =
             perform_job(ReportGenerationWorker, %{"simulation_report_id" => queued.id})

    report = Repo.get!(SimulationReport, queued.id)
    json = Simulations.export_analysis_json(pack)
    metrics = Simulations.export_analysis_metrics_csv(pack)
    events = Simulations.export_run_events_csv(record)
    transactions = Simulations.export_run_transactions_csv(record)
    markdown = Simulations.export_report_markdown(report)
    html = Simulations.export_report_html(report)

    hostile_markdown =
      Simulations.export_report_markdown(%{
        report
        | title: "<script>alert(1)</script>",
          summary: "[Open](javascript:alert(1))"
      })

    formula_safe_metrics =
      Simulations.export_analysis_metrics_csv(%{
        pack
        | metrics: [pack.metrics |> List.first() |> Map.put("id", "=2+2")]
      })

    assert Jason.decode!(json)["content_hash"] == pack.content_hash
    assert metrics =~ "reference,id,kind"
    assert events =~ "simulation.completed"
    assert transactions =~ "sequence,round,phase,resource"
    assert markdown =~ pack.content_hash
    assert markdown =~ "## Setup and question"
    assert html =~ "<!doctype html>"
    assert html =~ report.content_hash
    refute html =~ "<script>"
    assert hostile_markdown =~ "&lt;script&gt;"
    refute hostile_markdown =~ "<script>"
    refute hostile_markdown =~ "[Open](javascript:"
    assert formula_safe_metrics =~ "'=2+2"
  end

  defp valid_payload(reference) do
    %{
      "title" => "Validated simulation report",
      "summary" => "The result is directional and requires comparison with observed evidence.",
      "sections" =>
        Enum.map(1..9, fn _ ->
          %{
            "heading" => "Recorded finding",
            "body" => "The modeled outcome follows the recorded run state.",
            "references" => [reference]
          }
        end),
      "limitations" => ["The population is synthetic."],
      "recommended_next_steps" => ["Compare the direction with observed evidence."]
    }
  end
end
