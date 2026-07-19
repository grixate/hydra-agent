defmodule HydraAgent.Simulations.RunPack do
  @moduledoc "Deterministic, audit-complete `.hydra-run` export and inspection."

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime.RunEvent

  alias HydraAgent.Simulations.{
    AnalysisPack,
    Blueprint,
    IdentityRedactor,
    PortableArchive,
    ResourceTransaction,
    RunDecision,
    SimulationPack,
    SimulationReport,
    SimulationRunRecord
  }

  @format_version 1
  @required_files ~w(
    README.md
    simulation.hydra-simpack
    run.json
    events.jsonl
    decisions.json
    transactions.jsonl
    analysis.json
    reports.json
    usage.json
  )

  def format_version, do: @format_version
  def limits, do: PortableArchive.limits()

  def export(%SimulationRunRecord{} = record, %AnalysisPack{} = analysis, opts \\ []) do
    record = load_record(record)
    privacy = normalize_privacy(opts)

    with :ok <- require_completed(record, analysis),
         {:ok, simulation_export} <- export_run_simulation_pack(record, privacy),
         artifacts <- run_artifacts(record, analysis),
         artifacts <- apply_export_controls(artifacts, privacy),
         artifacts <- rehash_analysis(artifacts),
         files <- files(simulation_export.binary, artifacts),
         manifest <- manifest(record, artifacts.analysis, simulation_export, privacy),
         {:ok, export} <-
           PortableArchive.create(:run, files, manifest, filename(record, analysis)) do
      {:ok, Map.put(export, :privacy, privacy)}
    end
  end

  def import(binary) when is_binary(binary) do
    with {:ok, archive} <- PortableArchive.import(:run, binary),
         :ok <- validate_format_version(archive.manifest),
         :ok <- validate_compatibility(archive.manifest),
         :ok <- validate_privacy_manifest(archive.manifest),
         :ok <- require_files(archive.files),
         :ok <- validate_engine(archive.manifest),
         {:ok, simulation_pack} <-
           SimulationPack.import(archive.files["simulation.hydra-simpack"]),
         {:ok, run} <- decode_json(archive.files, "run.json"),
         {:ok, analysis} <- decode_json(archive.files, "analysis.json"),
         :ok <- validate_run_lineage(archive.manifest, simulation_pack, run, analysis) do
      {:ok,
       %{
         archive: archive,
         simulation_pack: simulation_pack,
         run: run,
         analysis: analysis,
         privacy: archive.manifest["privacy"] || %{}
       }}
    end
  end

  def import(_binary), do: error(:invalid_archive, "Run Pack must be binary ZIP data")

  defp load_record(record) do
    record =
      Repo.preload(record, [
        :run,
        :simulation,
        :context_pack,
        :population_model,
        :model_route_plan,
        :budget_plan,
        simulation_version: :blueprint_version,
        simulation_script: :preview
      ])

    blueprint_version = record.simulation_version.blueprint_version

    blueprint =
      Blueprint
      |> Repo.get(blueprint_version.blueprint_id)
      |> Repo.preload(:active_version)
      |> Map.put(:active_version, blueprint_version)
      |> Map.put(:active_version_id, blueprint_version.id)

    simulation =
      record.simulation
      |> Map.put(:title, record.simulation_version.title)
      |> Map.put(:question, record.simulation_version.question)
      |> Map.put(:locale, record.simulation_version.locale)
      |> Map.put(:active_version, record.simulation_version)
      |> Map.put(:active_version_id, record.simulation_version_id)
      |> Map.put(:active_context_pack, record.context_pack)
      |> Map.put(:active_context_pack_id, record.context_pack_id)
      |> Map.put(:active_population_model, record.population_model)
      |> Map.put(:active_population_model_id, record.population_model_id)
      |> Map.put(:active_script, record.simulation_script)
      |> Map.put(:active_script_id, record.simulation_script_id)
      |> Map.put(:selected_blueprint, blueprint)
      |> Map.put(:selected_blueprint_id, blueprint.id)

    Map.put(record, :simulation, simulation)
  end

  defp export_run_simulation_pack(record, privacy) do
    SimulationPack.export(record.simulation,
      model_route_plan: record.model_route_plan,
      budget_plan: record.budget_plan,
      include_raw_sources: privacy["raw_sources"] == "included",
      redact_identities: privacy["identities"] == "redacted",
      include_provider_details: privacy["provider_details"] == "included"
    )
  end

  defp run_artifacts(record, analysis) do
    reports =
      SimulationReport
      |> where([report], report.simulation_run_record_id == ^record.id)
      |> order_by([report], asc: report.version)
      |> Repo.all()

    %{
      run: run_json(record),
      events: event_json(record.run_id),
      decisions: decision_json(record.id),
      transactions: transaction_json(record.id),
      analysis: AnalysisPack.payload(analysis),
      reports: Enum.map(reports, &report_json/1),
      usage: usage_json(record, analysis, reports)
    }
  end

  defp run_json(record) do
    %{
      "schema_version" => 1,
      "protocol_version" => "hydra-run-record/v1",
      "mode" => record.mode,
      "replay_kind" => record.replay_kind,
      "seed" => record.seed,
      "engine_version" => record.engine_version,
      "pack_hash" => record.pack_hash,
      "decision_manifest_hash" => record.decision_manifest_hash,
      "decision_policy" => record.decision_policy,
      "partition_count" => record.partition_count,
      "snapshot_interval" => record.snapshot_interval,
      "rounds_planned" => record.rounds_planned,
      "rounds_completed" => record.current_round,
      "last_event_sequence" => record.last_event_sequence,
      "model_call_count" => record.model_call_count,
      "recovery_count" => record.recovery_count,
      "fallback_count" => record.fallback_count,
      "initial_state_hash" => record.initial_state_hash,
      "final_state_hash" => record.final_state_hash,
      "result_hash" => record.result_hash,
      "result_summary" => record.result_summary,
      "model_route_snapshot" => record.model_route_snapshot,
      "budget_snapshot" => record.budget_snapshot,
      "budget_used" => record.budget_used,
      "started_at" => iso8601(record.started_at),
      "completed_at" => iso8601(record.completed_at),
      "status" => record.run.status
    }
  end

  defp event_json(run_id) do
    RunEvent
    |> where([event], event.run_id == ^run_id)
    |> order_by([event], asc_nulls_first: event.sequence, asc: event.inserted_at, asc: event.id)
    |> Repo.all()
    |> Enum.map(fn event ->
      %{
        "event_type" => event.event_type,
        "summary" => event.summary,
        "payload" => event.payload,
        "sequence" => event.sequence,
        "round" => event.round,
        "phase" => event.phase,
        "actor_key" => event.actor_key,
        "targets" => event.targets,
        "source_ref" => event.source_ref,
        "provenance" => event.provenance,
        "idempotency_key" => event.idempotency_key,
        "recorded_at" => iso8601(event.inserted_at)
      }
    end)
  end

  defp decision_json(record_id) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^record_id)
    |> order_by([decision], asc: decision.sequence)
    |> Repo.all()
    |> Enum.map(fn decision ->
      %{
        "decision_key" => decision.decision_key,
        "sequence" => decision.sequence,
        "round" => decision.round,
        "policy_id" => decision.policy_id,
        "agent_type" => decision.agent_type,
        "archetype" => decision.archetype,
        "representative_agent_id" => decision.representative_agent_id,
        "policy_signature" => decision.policy_signature,
        "input_hash" => decision.input_hash,
        "prompt_snapshot" => decision.prompt_snapshot,
        "output" => decision.output,
        "action_id" => decision.action_id,
        "parameters" => decision.parameters,
        "reason_codes" => decision.reason_codes,
        "short_rationale" => decision.short_rationale,
        "uncertainty" => decimal(decision.uncertainty),
        "priority_score" => decimal(decision.priority_score),
        "score_components" => decision.score_components,
        "source" => decision.source,
        "provider" => decision.provider,
        "model" => decision.model,
        "model_route_version" => decision.model_route_version,
        "affected_agent_count" => decision.affected_agent_count,
        "reused_count" => decision.reused_count,
        "fallback" => decision.fallback,
        "input_tokens" => decision.input_tokens,
        "output_tokens" => decision.output_tokens,
        "cost" => decimal(decision.cost),
        "metadata" => decision.metadata,
        "recorded_at" => iso8601(decision.inserted_at)
      }
    end)
  end

  defp transaction_json(record_id) do
    ResourceTransaction
    |> where([transaction], transaction.simulation_run_record_id == ^record_id)
    |> order_by([transaction], asc: transaction.sequence)
    |> Repo.all()
    |> Enum.map(fn transaction ->
      %{
        "sequence" => transaction.sequence,
        "round" => transaction.round,
        "phase" => transaction.phase,
        "resource_id" => transaction.resource_id,
        "source_account" => transaction.source_account,
        "destination_account" => transaction.destination_account,
        "amount" => decimal(transaction.amount),
        "operation" => transaction.operation,
        "source_ref" => transaction.source_ref,
        "tags" => transaction.tags,
        "resulting_balances" => transaction.resulting_balances,
        "idempotency_key" => transaction.idempotency_key,
        "recorded_at" => iso8601(transaction.inserted_at)
      }
    end)
  end

  defp report_json(report) do
    %{
      "version" => report.version,
      "status" => report.status,
      "locale" => report.locale,
      "audience" => report.audience,
      "length" => report.length,
      "provider" => report.provider,
      "model" => report.model,
      "model_route_version" => report.model_route_version,
      "route_snapshot" => report.route_snapshot,
      "price_snapshot" => report.price_snapshot,
      "currency" => report.currency,
      "pricing_known" => report.pricing_known,
      "reserved_cost" => decimal(report.reserved_cost),
      "actual_input_tokens" => report.actual_input_tokens,
      "actual_output_tokens" => report.actual_output_tokens,
      "actual_cost" => decimal(report.actual_cost),
      "blueprint_version_hash" => report.blueprint_version_hash,
      "instructions_hash" => report.instructions_hash,
      "analysis_hash" => report.analysis_hash,
      "title" => report.title,
      "summary" => report.summary,
      "sections" => report.sections,
      "limitations" => report.limitations,
      "recommended_next_steps" => report.recommended_next_steps,
      "validation_status" => report.validation_status,
      "validation_errors" => report.validation_errors,
      "content_hash" => report.content_hash,
      "failure" => report.failure,
      "started_at" => iso8601(report.started_at),
      "completed_at" => iso8601(report.completed_at)
    }
  end

  defp usage_json(record, analysis, reports) do
    %{
      "schema_version" => 1,
      "simulation" => record.budget_used,
      "analysis" => analysis.usage,
      "reports" =>
        Enum.map(reports, fn report ->
          %{
            "version" => report.version,
            "input_tokens" => report.actual_input_tokens,
            "output_tokens" => report.actual_output_tokens,
            "cost" => decimal(report.actual_cost),
            "currency" => report.currency,
            "pricing_known" => report.pricing_known
          }
        end),
      "totals" => %{
        "model_calls" => record.model_call_count,
        "fallbacks" => record.fallback_count,
        "recoveries" => record.recovery_count,
        "recorded_decisions" => length(analysis.model_decisions),
        "reports" => length(reports)
      }
    }
  end

  defp normalize_privacy(opts) do
    redact = Keyword.get(opts, :redact_identities, false) == true

    %{
      "raw_sources" =>
        if(Keyword.get(opts, :include_raw_sources, false) == true and not redact,
          do: "included",
          else: "excluded"
        ),
      "identities" => if(redact, do: "redacted", else: "original"),
      "model_rationales" =>
        if(Keyword.get(opts, :include_model_rationales, true) == false,
          do: "omitted",
          else: "included"
        ),
      "provider_details" =>
        if(Keyword.get(opts, :include_provider_details, true) == false,
          do: "omitted",
          else: "included"
        ),
      "snapshots" => "excluded",
      "redaction_version" => if(redact, do: "hydra-redaction/v1", else: nil)
    }
  end

  defp apply_export_controls(artifacts, privacy) do
    artifacts
    |> maybe_omit_rationales(privacy)
    |> maybe_omit_providers(privacy)
    |> maybe_redact(privacy)
  end

  defp maybe_omit_rationales(artifacts, %{"model_rationales" => "omitted"}) do
    decisions =
      Enum.map(artifacts.decisions, fn decision ->
        Map.drop(decision, ~w(prompt_snapshot output short_rationale score_components))
      end)

    analysis =
      Map.update(artifacts.analysis, "model_decisions", [], fn decisions ->
        Enum.map(
          decisions,
          &Map.drop(&1, ~w(prompt prompt_snapshot output rationale short_rationale))
        )
      end)

    %{artifacts | decisions: decisions, analysis: analysis}
  end

  defp maybe_omit_rationales(artifacts, _privacy), do: artifacts

  defp maybe_omit_providers(artifacts, %{"provider_details" => "omitted"}) do
    run = Map.update(artifacts.run, "model_route_snapshot", %{}, &omit_route_details/1)

    decisions =
      Enum.map(artifacts.decisions, &Map.drop(&1, ~w(provider model model_route_version)))

    reports =
      Enum.map(artifacts.reports, fn report ->
        report
        |> Map.drop(~w(provider model model_route_version price_snapshot))
        |> Map.update("route_snapshot", %{}, &omit_route_details/1)
      end)

    %{artifacts | run: run, decisions: decisions, reports: reports}
  end

  defp maybe_omit_providers(artifacts, _privacy), do: artifacts

  defp omit_route_details(routes) when is_map(routes) do
    Map.new(routes, fn {role, route} ->
      {role,
       route
       |> Map.drop(~w(id name provider model))
       |> Map.put("provider_details", "omitted")}
    end)
  end

  defp omit_route_details(_routes), do: %{}

  defp maybe_redact(artifacts, %{"identities" => "redacted"}) do
    redactor = IdentityRedactor.new(Map.values(artifacts))
    Map.new(artifacts, fn {key, value} -> {key, IdentityRedactor.redact(value, redactor)} end)
  end

  defp maybe_redact(artifacts, _privacy), do: artifacts

  defp rehash_analysis(artifacts) do
    analysis =
      Map.put(artifacts.analysis, "content_hash", analysis_content_hash(artifacts.analysis))

    %{artifacts | analysis: analysis}
  end

  defp files(simulation_pack, artifacts) do
    %{
      "README.md" => readme(artifacts.run),
      "simulation.hydra-simpack" => simulation_pack,
      "run.json" => PortableArchive.json(artifacts.run),
      "events.jsonl" => jsonl(artifacts.events),
      "decisions.json" => PortableArchive.json(%{"decisions" => artifacts.decisions}),
      "transactions.jsonl" => jsonl(artifacts.transactions),
      "analysis.json" => PortableArchive.json(artifacts.analysis),
      "reports.json" => PortableArchive.json(%{"reports" => artifacts.reports}),
      "usage.json" => PortableArchive.json(artifacts.usage)
    }
  end

  defp manifest(record, analysis, simulation_export, privacy) do
    %{
      "format_version" => @format_version,
      "created_at" => iso8601(record.completed_at),
      "hydra_version" => hydra_version(),
      "compatibility" => %{
        "minimum_hydra_version" => "0.1.0",
        "run_schema" => 1,
        "analysis_schema" => analysis["schema_version"],
        "engine_version" => record.engine_version
      },
      "lineage" => %{
        "simulation_pack_artifact_hash" => simulation_export.content_hash,
        "run_pack_hash" => record.pack_hash,
        "result_hash" => record.result_hash,
        "decision_manifest_hash" => record.decision_manifest_hash,
        "analysis_hash" => analysis["content_hash"],
        "seed" => record.seed,
        "replay_kind" => record.replay_kind
      },
      "privacy" => privacy,
      "validation" => %{
        "run_status" => record.run.status,
        "analysis" => "passed",
        "result_hash" => if(record.result_hash, do: "present", else: "missing")
      }
    }
  end

  defp readme(run) do
    """
    # Hydra Run Pack

    This package is a portable, immutable audit record for one completed synthetic simulation Run. It contains no executable code and no provider credentials.

    ## Verify

    1. Verify every file against `manifest.json`.
    2. Import or inspect `simulation.hydra-simpack` to validate the exact declarative inputs.
    3. Confirm the engine version, seed, Pack hash, decision manifest, and final result hash in `run.json`.
    4. Recompute deterministic analysis from the event and transaction record and compare it with `analysis.json`.

    ## Reproduce

    - Engine: `#{run["engine_version"]}`
    - Seed: `#{run["seed"]}`
    - Pack hash: `#{run["pack_hash"]}`
    - Result hash: `#{run["result_hash"]}`

    Quick Runs reproduce from the Simulation Pack, seed, and engine version. Balanced exact replay additionally uses the recorded decisions in `decisions.json`. A fresh rerun may produce different model decisions and is recorded as a new Run.

    Run snapshots are intentionally excluded: the append-only events, transactions, decisions, hashes, deterministic Analysis Pack, usage, and reports form the portable audit record without duplicating large recoverability state.
    """
  end

  defp require_completed(record, analysis) do
    cond do
      record.run.status != "completed" or is_nil(record.result_hash) ->
        error(:run_not_completed, "Only completed Runs can be exported")

      analysis.simulation_run_record_id != record.id ->
        error(:analysis_lineage_mismatch, "Analysis Pack does not belong to this Run")

      true ->
        :ok
    end
  end

  defp validate_format_version(manifest) do
    case manifest["format_version"] do
      @format_version ->
        :ok

      version when is_integer(version) ->
        error(
          :unsupported_format_version,
          "This Run Pack uses format v#{version}; this Hydra supports v#{@format_version}. Upgrade Hydra or re-export as v#{@format_version}."
        )

      _ ->
        error(:invalid_format_version, "Run Pack format_version must be an integer")
    end
  end

  defp require_files(files) do
    missing = @required_files -- Map.keys(files)
    unexpected = Map.keys(files) -- @required_files

    cond do
      missing != [] -> error(:missing_files, "Run Pack is incomplete", missing)
      unexpected != [] -> error(:unexpected_files, "Run Pack contains unknown files", unexpected)
      true -> :ok
    end
  end

  defp validate_compatibility(manifest) do
    compatibility = manifest["compatibility"]

    cond do
      not is_map(compatibility) ->
        error(:invalid_compatibility, "Run Pack compatibility must be an object")

      not valid_semver?(compatibility["minimum_hydra_version"]) ->
        error(:invalid_compatibility, "Run Pack minimum Hydra version is invalid")

      Version.compare(hydra_version(), compatibility["minimum_hydra_version"]) == :lt ->
        error(
          :hydra_upgrade_required,
          "This Run Pack requires Hydra #{compatibility["minimum_hydra_version"]} or newer; this deployment is #{hydra_version()}."
        )

      compatibility["run_schema"] != 1 or compatibility["analysis_schema"] != 1 ->
        error(:unsupported_schema_version, "This Run Pack uses an unsupported schema")

      true ->
        :ok
    end
  end

  defp validate_privacy_manifest(manifest) do
    privacy = manifest["privacy"]

    cond do
      not is_map(privacy) ->
        error(:invalid_privacy_manifest, "Run Pack privacy must be an object")

      privacy["raw_sources"] not in ~w(included excluded) or
        privacy["identities"] not in ~w(original redacted) or
        privacy["model_rationales"] not in ~w(included omitted) or
        privacy["provider_details"] not in ~w(included omitted) or
          privacy["snapshots"] != "excluded" ->
        error(:invalid_privacy_manifest, "Run Pack privacy controls are invalid")

      privacy["identities"] == "redacted" and privacy["raw_sources"] != "excluded" ->
        error(:invalid_privacy_manifest, "Redacted Run Packs cannot include raw sources")

      privacy["identities"] == "redacted" and
          privacy["redaction_version"] != "hydra-redaction/v1" ->
        error(:invalid_privacy_manifest, "Run Pack redaction version is unsupported")

      privacy["identities"] == "original" and not is_nil(privacy["redaction_version"]) ->
        error(:invalid_privacy_manifest, "Unredacted Run Packs cannot claim redaction")

      true ->
        :ok
    end
  end

  defp validate_engine(manifest) do
    engine = get_in(manifest, ["compatibility", "engine_version"])

    supported = [
      SimulationRunRecord.engine_version("quick"),
      SimulationRunRecord.engine_version("balanced")
    ]

    if engine in supported,
      do: :ok,
      else:
        error(
          :unsupported_engine_version,
          "This Run Pack uses engine #{engine || "unknown"}; install a compatible Hydra version to replay it."
        )
  end

  defp validate_run_lineage(manifest, simulation_pack, run, analysis) do
    lineage = manifest["lineage"] || %{}

    cond do
      simulation_pack.archive.content_hash != lineage["simulation_pack_artifact_hash"] ->
        error(
          :simulation_pack_hash_mismatch,
          "Embedded Simulation Pack does not match Run Pack lineage"
        )

      run["status"] != "completed" ->
        error(:run_not_completed, "Run Pack record is not completed")

      not is_binary(run["result_hash"]) or run["result_hash"] != lineage["result_hash"] ->
        error(:result_hash_mismatch, "Run Pack result hash does not match its manifest")

      analysis["content_hash"] != lineage["analysis_hash"] ->
        error(:analysis_hash_mismatch, "Run Pack Analysis hash does not match its manifest")

      analysis["content_hash"] != analysis_content_hash(analysis) ->
        error(:analysis_hash_mismatch, "Run Pack Analysis content hash does not match")

      true ->
        :ok
    end
  end

  defp analysis_content_hash(analysis) do
    analysis
    |> Map.take(~w(
        schema_version protocol_version setup metrics segments timeline resource_flows
        pivotal_events representative_traces model_decisions scenario_deltas robustness
        uncertainty grounding_refs usage limitations reference_index
      ))
    |> HydraAgent.Simulations.ContentHash.digest()
  end

  defp valid_semver?(value) when is_binary(value), do: Version.parse(value) != :error
  defp valid_semver?(_value), do: false

  defp decode_json(files, path) do
    case Jason.decode(files[path] || "") do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> error(:invalid_json, "#{path} must contain a JSON object")
    end
  end

  defp filename(record, analysis) do
    "hydra-run-#{String.slice(record.result_hash, 0, 10)}-#{String.slice(analysis.content_hash, 0, 10)}.hydra-run"
  end

  defp jsonl([]), do: ""
  defp jsonl(values), do: Enum.map_join(values, "", &(Jason.encode!(&1) <> "\n"))

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal(value), do: value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp hydra_version do
    case Application.spec(:hydra_agent, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end

  defp error(code, message, detail \\ nil),
    do: {:error, %{code: code, message: message, detail: detail}}
end
