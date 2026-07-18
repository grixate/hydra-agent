defmodule HydraAgent.Audit do
  @moduledoc """
  Workspace audit export.
  """

  import Ecto.Query

  alias HydraAgent.{
    Automations,
    Budgets,
    Evals,
    Gateways,
    MCP,
    Providers,
    Repo,
    Runtime,
    Safety
  }

  alias HydraAgent.Runtime.RunEvent
  alias HydraAgent.SimLab.SimulationRunner
  alias HydraAgent.Simulations.Blueprint, as: SimulationBlueprint
  alias HydraAgent.Simulations.BlueprintVersion, as: SimulationBlueprintVersion
  alias HydraAgent.Simulations.BuildStage, as: SimulationBuildStage
  alias HydraAgent.Simulations.ContextPack, as: SimulationContextPack
  alias HydraAgent.Simulations.ContextResearchRun, as: SimulationContextResearchRun
  alias HydraAgent.Simulations.PersonaProjection, as: SimulationPersonaProjection
  alias HydraAgent.Simulations.PopulationModel, as: SimulationPopulationModel
  alias HydraAgent.Simulations.Simulation, as: StudioSimulation
  alias HydraAgent.Simulations.SimulationVersion, as: StudioSimulationVersion

  alias HydraAgent.SimLab.Schemas.{
    ActionPattern,
    CalibrationRecord,
    ContextPack,
    EvidenceItem,
    ForecastReport,
    OutcomeEvent,
    Persona,
    ResearchRun,
    Scenario,
    SimulationRun,
    SimulationSnapshot,
    Source,
    Study
  }

  alias HydraAgent.Tools.{Bundles, Registry}

  @source_metadata_keys ~w(
    entry_type filename extension lane purpose region language provider_reliability
    provider_mode synthetic_test pii_findings removed_from_study
  )
  @source_access_policy_keys ~w(scope external_send retrieval review_required synthetic_test)
  @evidence_source_ref_keys ~w(source_id kind uri url title lane reference)
  @evidence_metadata_keys ~w(review_status safe_query provider_mode synthetic_test)
  @context_summary_keys ~w(
    research_status synthesis_scope source_count evidence_count local_entry_count domain audience
    behavior provider_mode failed_lane_count
  )

  def export_workspace(workspace_id) do
    workspace = Runtime.get_workspace!(workspace_id)

    %{
      "workspace" => %{
        "id" => workspace.id,
        "name" => workspace.name,
        "slug" => workspace.slug,
        "status" => workspace.status
      },
      "exported_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "agents" => Enum.map(Runtime.list_agents(workspace_id), &agent_json/1),
      "providers" => Enum.map(Providers.list_configs(workspace_id), &provider_json/1),
      "budgets" => Enum.map(Budgets.list_budgets(workspace_id), &budget_json/1),
      "tool_policies" => Enum.map(Runtime.list_tool_policies(workspace_id), &policy_json/1),
      "tools" => Registry.all(),
      "tool_bundles" => Bundles.all(),
      "mcp_servers" => Enum.map(MCP.list_servers(workspace_id), &mcp_server_json/1),
      "runs" => Enum.map(Runtime.list_runs(workspace_id), &run_json/1),
      "run_events" => Enum.map(run_events(workspace_id), &run_event_json/1),
      "safety_events" =>
        Enum.map(Safety.list_events(workspace_id, limit: 1000), &safety_event_json/1),
      "automations" => Enum.map(Automations.list_automations(workspace_id), &automation_json/1),
      "webhooks" => Enum.map(Gateways.list_webhooks(workspace_id), &webhook_json/1),
      "eval_suites" => Enum.map(Evals.list_suites(workspace_id), &suite_json/1),
      "simulation_studio" => simulation_studio_json(workspace_id),
      "sim_lab" => sim_lab_json(workspace_id)
    }
  end

  defp simulation_studio_json(workspace_id) do
    %{
      "blueprints" =>
        map_records(simulation_blueprints(workspace_id), &simulation_blueprint_json/1),
      "blueprint_versions" =>
        map_records(
          simulation_blueprint_versions(workspace_id),
          &simulation_blueprint_version_json/1
        ),
      "simulations" => map_records(studio_simulations(workspace_id), &studio_simulation_json/1),
      "simulation_versions" =>
        map_records(studio_simulation_versions(workspace_id), &studio_simulation_version_json/1),
      "build_stages" =>
        map_records(simulation_build_stages(workspace_id), &simulation_build_stage_json/1),
      "context_packs" =>
        map_records(simulation_context_packs(workspace_id), &simulation_context_pack_json/1),
      "context_research_runs" =>
        map_records(
          simulation_context_research_runs(workspace_id),
          &simulation_context_research_run_json/1
        ),
      "population_models" =>
        map_records(
          simulation_population_models(workspace_id),
          &simulation_population_model_json/1
        ),
      "persona_projections" =>
        map_records(
          simulation_persona_projections(workspace_id),
          &simulation_persona_projection_json/1
        )
    }
  end

  defp simulation_blueprints(workspace_id) do
    SimulationBlueprint
    |> where(
      [blueprint],
      (blueprint.built_in and is_nil(blueprint.workspace_id)) or
        blueprint.workspace_id == ^workspace_id
    )
    |> order_by([blueprint], desc: blueprint.built_in, asc: blueprint.id)
    |> Repo.all()
  end

  defp simulation_blueprint_versions(workspace_id) do
    SimulationBlueprintVersion
    |> join(:inner, [version], blueprint in SimulationBlueprint,
      on: blueprint.id == version.blueprint_id
    )
    |> where(
      [_version, blueprint],
      (blueprint.built_in and is_nil(blueprint.workspace_id)) or
        blueprint.workspace_id == ^workspace_id
    )
    |> order_by([version], asc: version.blueprint_id, asc: version.id)
    |> Repo.all()
  end

  defp studio_simulations(workspace_id) do
    StudioSimulation
    |> where([simulation], simulation.workspace_id == ^workspace_id)
    |> order_by([simulation], asc: simulation.id)
    |> Repo.all()
  end

  defp studio_simulation_versions(workspace_id) do
    StudioSimulationVersion
    |> where([version], version.workspace_id == ^workspace_id)
    |> order_by([version], asc: version.simulation_id, asc: version.version)
    |> Repo.all()
  end

  defp simulation_build_stages(workspace_id) do
    SimulationBuildStage
    |> where([stage], stage.workspace_id == ^workspace_id)
    |> order_by([stage], asc: stage.simulation_version_id, asc: stage.ordinal)
    |> Repo.all()
  end

  defp simulation_context_packs(workspace_id) do
    SimulationContextPack
    |> where([pack], pack.workspace_id == ^workspace_id)
    |> order_by([pack], asc: pack.simulation_version_id, asc: pack.version)
    |> Repo.all()
  end

  defp simulation_context_research_runs(workspace_id) do
    SimulationContextResearchRun
    |> where([run], run.workspace_id == ^workspace_id)
    |> order_by([run], asc: run.simulation_version_id, asc: run.id)
    |> Repo.all()
  end

  defp simulation_population_models(workspace_id) do
    SimulationPopulationModel
    |> where([model], model.workspace_id == ^workspace_id)
    |> order_by([model], asc: model.simulation_version_id, asc: model.version)
    |> Repo.all()
  end

  defp simulation_persona_projections(workspace_id) do
    SimulationPersonaProjection
    |> where([projection], projection.workspace_id == ^workspace_id)
    |> order_by([projection], asc: projection.population_model_id, asc: projection.id)
    |> Repo.all()
  end

  defp sim_lab_json(workspace_id) do
    %{
      "studies" => map_records(sim_lab_studies(workspace_id), &study_json/1),
      "sources" => map_records(sim_lab_sources(workspace_id), &source_json/1),
      "evidence_items" =>
        map_records(sim_lab_evidence_items(workspace_id), &evidence_item_json/1),
      "context_packs" => map_records(sim_lab_context_packs(workspace_id), &context_pack_json/1),
      "personas" => map_records(sim_lab_personas(workspace_id), &persona_json/1),
      "action_patterns" =>
        map_records(sim_lab_action_patterns(workspace_id), &action_pattern_json/1),
      "scenarios" => map_records(sim_lab_scenarios(workspace_id), &scenario_json/1),
      "simulation_runs" =>
        map_records(sim_lab_simulation_runs(workspace_id), &simulation_run_json/1),
      "snapshots" => map_records(sim_lab_snapshots(workspace_id), &snapshot_json/1),
      "outcome_events" =>
        map_records(sim_lab_outcome_events(workspace_id), &outcome_event_json/1),
      "forecast_reports" =>
        map_records(sim_lab_forecast_reports(workspace_id), &forecast_report_json/1),
      "calibrations" => map_records(sim_lab_calibrations(workspace_id), &calibration_json/1),
      "research_runs" => map_records(sim_lab_research_runs(workspace_id), &research_run_json/1)
    }
  end

  defp sim_lab_studies(workspace_id) do
    Study
    |> where([study], study.workspace_id == ^workspace_id)
    |> order_by([study], asc: study.id)
    |> Repo.all()
  end

  defp sim_lab_sources(workspace_id) do
    Source
    |> join(:inner, [source], study in Study, on: study.id == source.study_id)
    |> where(
      [source, study],
      source.workspace_id == ^workspace_id and study.workspace_id == ^workspace_id
    )
    |> order_by([source], asc: source.id)
    |> Repo.all()
  end

  defp sim_lab_evidence_items(workspace_id) do
    EvidenceItem
    |> join(:inner, [item], study in Study, on: study.id == item.study_id)
    |> where([_item, study], study.workspace_id == ^workspace_id)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp sim_lab_context_packs(workspace_id) do
    ContextPack
    |> join(:inner, [pack], study in Study, on: study.id == pack.study_id)
    |> where([_pack, study], study.workspace_id == ^workspace_id)
    |> order_by([pack], asc: pack.id)
    |> Repo.all()
  end

  defp sim_lab_personas(workspace_id) do
    Persona
    |> join(:inner, [persona], study in Study, on: study.id == persona.study_id)
    |> where([_persona, study], study.workspace_id == ^workspace_id)
    |> order_by([persona], asc: persona.id)
    |> Repo.all()
  end

  defp sim_lab_action_patterns(workspace_id) do
    ActionPattern
    |> join(:inner, [pattern], study in Study, on: study.id == pattern.study_id)
    |> where([_pattern, study], study.workspace_id == ^workspace_id)
    |> order_by([pattern], asc: pattern.id)
    |> Repo.all()
  end

  defp sim_lab_scenarios(workspace_id) do
    Scenario
    |> join(:inner, [scenario], study in Study, on: study.id == scenario.study_id)
    |> where([_scenario, study], study.workspace_id == ^workspace_id)
    |> order_by([scenario], asc: scenario.id)
    |> Repo.all()
  end

  defp sim_lab_simulation_runs(workspace_id) do
    SimulationRun
    |> join(:inner, [run], study in Study, on: study.id == run.study_id)
    |> where([_run, study], study.workspace_id == ^workspace_id)
    |> order_by([run], asc: run.id)
    |> Repo.all()
  end

  defp sim_lab_snapshots(workspace_id) do
    SimulationSnapshot
    |> join(:inner, [snapshot], run in SimulationRun, on: run.id == snapshot.run_id)
    |> join(:inner, [_snapshot, run], study in Study, on: study.id == run.study_id)
    |> where([_snapshot, _run, study], study.workspace_id == ^workspace_id)
    |> order_by([snapshot], asc: snapshot.run_id, asc: snapshot.tick, asc: snapshot.id)
    |> Repo.all()
  end

  defp sim_lab_outcome_events(workspace_id) do
    OutcomeEvent
    |> join(:inner, [event], run in SimulationRun, on: run.id == event.run_id)
    |> join(:inner, [_event, run], study in Study, on: study.id == run.study_id)
    |> where([_event, _run, study], study.workspace_id == ^workspace_id)
    |> order_by([event], asc: event.run_id, asc: event.tick, asc: event.id)
    |> Repo.all()
  end

  defp sim_lab_forecast_reports(workspace_id) do
    ForecastReport
    |> join(:inner, [report], run in SimulationRun, on: run.id == report.run_id)
    |> join(
      :inner,
      [report, run],
      study in Study,
      on: study.id == report.study_id and run.study_id == study.id
    )
    |> where([_report, _run, study], study.workspace_id == ^workspace_id)
    |> order_by([report], asc: report.id)
    |> Repo.all()
  end

  defp sim_lab_calibrations(workspace_id) do
    CalibrationRecord
    |> join(:inner, [record], run in SimulationRun, on: run.id == record.run_id)
    |> join(
      :inner,
      [record, run],
      study in Study,
      on: study.id == record.study_id and run.study_id == study.id
    )
    |> where([_record, _run, study], study.workspace_id == ^workspace_id)
    |> order_by([record], asc: record.id)
    |> Repo.all()
  end

  defp sim_lab_research_runs(workspace_id) do
    ResearchRun
    |> join(:inner, [run], study in Study, on: study.id == run.study_id)
    |> where(
      [run, study],
      run.workspace_id == ^workspace_id and study.workspace_id == ^workspace_id
    )
    |> order_by([run], asc: run.id)
    |> Repo.all()
  end

  defp run_events(workspace_id) do
    RunEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> order_by([event], asc: event.inserted_at)
    |> limit(1000)
    |> Repo.all()
  end

  defp agent_json(agent) do
    %{
      "id" => agent.id,
      "slug" => agent.slug,
      "name" => agent.name,
      "role" => agent.role,
      "status" => agent.status,
      "model_route" => agent.model_route,
      "capability_profile" => agent.capability_profile
    }
  end

  defp provider_json(provider) do
    %{
      "id" => provider.id,
      "name" => provider.name,
      "kind" => provider.kind,
      "model" => provider.model,
      "api_key_ref" => HydraAgent.Secrets.safe_ref(provider.api_key_env),
      "enabled" => provider.enabled,
      "metadata" => provider.metadata
    }
  end

  defp budget_json(budget) do
    %{
      "id" => budget.id,
      "agent_id" => budget.agent_id,
      "name" => budget.name,
      "status" => budget.status,
      "category" => budget.category,
      "period" => budget.period,
      "token_limit" => budget.token_limit,
      "cost_limit" => if(budget.cost_limit, do: Decimal.to_string(budget.cost_limit), else: nil),
      "metadata" => budget.metadata
    }
  end

  defp policy_json(policy) do
    %{
      "id" => policy.id,
      "agent_id" => policy.agent_id,
      "scope" => policy.scope,
      "allowed_tools" => policy.allowed_tools,
      "side_effect_classes" => policy.side_effect_classes,
      "network_allowlist" => policy.network_allowlist,
      "shell_allowlist" => policy.shell_allowlist,
      "shell_env_allowlist" => Map.get(policy, :shell_env_allowlist, []),
      "filesystem_allowlist" => Map.get(policy, :filesystem_allowlist, []),
      "filesystem_denylist" => Map.get(policy, :filesystem_denylist, []),
      "tool_bundles" => get_in(policy.metadata || %{}, ["tool_bundles"]) || [],
      "requires_approval" => policy.requires_approval
    }
  end

  defp mcp_server_json(server) do
    %{
      "id" => server.id,
      "slug" => server.slug,
      "name" => server.name,
      "status" => server.status,
      "transport" => server.transport,
      "trust_level" => server.trust_level,
      "env_refs" => server.env_refs,
      "include_tools" => server.include_tools,
      "exclude_tools" => server.exclude_tools,
      "resource_access" => server.resource_access,
      "prompt_access" => server.prompt_access,
      "timeout_ms" => server.timeout_ms,
      "approval_sensitive" => server.approval_sensitive,
      "health_status" => server.health_status,
      "last_checked_at" => server.last_checked_at,
      "last_error" => server.last_error,
      "metadata" => server.metadata
    }
  end

  defp run_json(run) do
    %{
      "id" => run.id,
      "title" => run.title,
      "goal" => run.goal,
      "status" => run.status,
      "autonomy_level" => run.autonomy_level,
      "supervisor_agent_id" => run.supervisor_agent_id,
      "steps" => Enum.map(loaded(run.steps), &step_json/1)
    }
  end

  defp step_json(step) do
    %{
      "id" => step.id,
      "index" => step.index,
      "title" => step.title,
      "status" => step.status,
      "tool_name" => step.tool_name,
      "side_effect_class" => step.side_effect_class,
      "attempt_count" => Map.get(step, :attempt_count)
    }
  end

  defp run_event_json(event) do
    %{
      "id" => event.id,
      "run_id" => event.run_id,
      "run_step_id" => event.run_step_id,
      "agent_id" => event.agent_id,
      "event_type" => event.event_type,
      "summary" => event.summary,
      "payload" => event.payload,
      "inserted_at" => event.inserted_at
    }
  end

  defp safety_event_json(event) do
    %{
      "id" => event.id,
      "agent_id" => event.agent_id,
      "run_id" => event.run_id,
      "run_step_id" => event.run_step_id,
      "category" => event.category,
      "severity" => event.severity,
      "action" => event.action,
      "summary" => event.summary,
      "metadata" => event.metadata,
      "inserted_at" => event.inserted_at
    }
  end

  defp automation_json(automation) do
    %{
      "id" => automation.id,
      "agent_id" => automation.agent_id,
      "slug" => automation.slug,
      "name" => automation.name,
      "status" => automation.status,
      "cron_expression" => automation.cron_expression,
      "next_run_at" => automation.next_run_at,
      "last_run_at" => automation.last_run_at,
      "last_error" => automation.last_error
    }
  end

  defp webhook_json(webhook) do
    %{
      "id" => webhook.id,
      "agent_id" => webhook.agent_id,
      "slug" => webhook.slug,
      "name" => webhook.name,
      "status" => webhook.status,
      "target_type" => webhook.target_type,
      "token_ref" => HydraAgent.Secrets.safe_ref(webhook.token_env),
      "last_received_at" => webhook.last_received_at,
      "last_error" => webhook.last_error
    }
  end

  defp suite_json(suite) do
    %{
      "id" => suite.id,
      "slug" => suite.slug,
      "name" => suite.name,
      "status" => suite.status
    }
  end

  defp simulation_blueprint_json(blueprint) do
    %{
      "id" => blueprint.id,
      "workspace_id" => blueprint.workspace_id,
      "owner_user_id" => blueprint.owner_user_id,
      "source_blueprint_id" => blueprint.source_blueprint_id,
      "active_version_id" => blueprint.active_version_id,
      "slug" => blueprint.slug,
      "name" => blueprint.name,
      "description" => blueprint.description,
      "status" => blueprint.status,
      "built_in" => blueprint.built_in,
      "origin" => blueprint.origin,
      "inserted_at" => blueprint.inserted_at,
      "updated_at" => blueprint.updated_at
    }
  end

  defp simulation_blueprint_version_json(version) do
    %{
      "id" => version.id,
      "workspace_id" => version.workspace_id,
      "blueprint_id" => version.blueprint_id,
      "created_by_user_id" => version.created_by_user_id,
      "version" => version.version,
      "manifest" => version.manifest,
      "instruction_fingerprints" =>
        Map.new(version.instructions || %{}, fn {name, instructions} ->
          {name, fingerprint(instructions)}
        end),
      "schema_paths" => version.schemas |> Map.keys() |> Enum.sort(),
      "example_paths" => version.examples |> Map.keys() |> Enum.sort(),
      "readme_fingerprint" => fingerprint(version.readme),
      "capability_requirements" => version.capability_requirements,
      "content_hash" => version.content_hash,
      "validation_status" => version.validation_status,
      "validation_errors" => version.validation_errors,
      "compatibility_warnings" => version.compatibility_warnings,
      "inserted_at" => version.inserted_at
    }
  end

  defp studio_simulation_json(simulation) do
    %{
      "id" => simulation.id,
      "workspace_id" => simulation.workspace_id,
      "selected_blueprint_id" => simulation.selected_blueprint_id,
      "owner_user_id" => simulation.owner_user_id,
      "source_simulation_id" => simulation.source_simulation_id,
      "legacy_study_id" => simulation.legacy_study_id,
      "active_version_id" => simulation.active_version_id,
      "active_context_pack_id" => simulation.active_context_pack_id,
      "active_population_model_id" => simulation.active_population_model_id,
      "title" => simulation.title,
      "question" => simulation.question,
      "locale" => simulation.locale,
      "status" => simulation.status,
      "archived_at" => simulation.archived_at,
      "inserted_at" => simulation.inserted_at,
      "updated_at" => simulation.updated_at
    }
  end

  defp studio_simulation_version_json(version) do
    %{
      "id" => version.id,
      "workspace_id" => version.workspace_id,
      "simulation_id" => version.simulation_id,
      "blueprint_version_id" => version.blueprint_version_id,
      "created_by_user_id" => version.created_by_user_id,
      "version" => version.version,
      "title" => version.title,
      "question" => version.question,
      "locale" => version.locale,
      "normalized_input" => version.normalized_input,
      "input_summary" => audit_input_summary(version.inputs),
      "instruction_override_fingerprints" =>
        Map.new(version.instruction_overrides || %{}, fn {name, instructions} ->
          {name, fingerprint(instructions)}
        end),
      "research_settings" => version.research_settings,
      "population_size" => version.population_size,
      "execution_mode" => version.execution_mode,
      "budget_preset" => version.budget_preset,
      "model_routes" => version.model_routes,
      "content_hash" => version.content_hash,
      "inserted_at" => version.inserted_at
    }
  end

  defp audit_input_summary(inputs) do
    inputs = inputs || %{}

    %{
      "notes_fingerprint" => fingerprint(inputs["notes"]),
      "urls" =>
        Enum.map(inputs["urls"] || [], fn entry ->
          uri = entry["uri"]

          %{
            "uri" => safe_source_uri(uri),
            "uri_hash" => fingerprint(uri),
            "status" => entry["status"]
          }
        end),
      "files" =>
        Enum.map(inputs["files"] || [], fn file ->
          %{
            "filename" => file["filename"],
            "extension" => file["extension"],
            "media_type" => file["media_type"],
            "size_bytes" => file["size_bytes"],
            "sha256" => file["sha256"]
          }
        end)
    }
  end

  defp simulation_build_stage_json(stage) do
    %{
      "id" => stage.id,
      "workspace_id" => stage.workspace_id,
      "simulation_id" => stage.simulation_id,
      "simulation_version_id" => stage.simulation_version_id,
      "stage" => stage.stage,
      "ordinal" => stage.ordinal,
      "status" => stage.status,
      "summary" => stage.summary,
      "warnings" => stage.warnings,
      "started_at" => stage.started_at,
      "completed_at" => stage.completed_at,
      "inserted_at" => stage.inserted_at,
      "updated_at" => stage.updated_at
    }
  end

  defp simulation_context_pack_json(pack) do
    %{
      "id" => pack.id,
      "workspace_id" => pack.workspace_id,
      "simulation_id" => pack.simulation_id,
      "simulation_version_id" => pack.simulation_version_id,
      "created_by_user_id" => pack.created_by_user_id,
      "version" => pack.version,
      "interpretation" => %{
        "primary_question_fingerprint" => fingerprint(pack.interpretation["primary_question"]),
        "world_fingerprint" => fingerprint(pack.interpretation["world"]),
        "agent_types" => pack.interpretation["agent_types"],
        "candidate_resources" => pack.interpretation["candidate_resources"],
        "candidate_actions" => pack.interpretation["candidate_actions"],
        "missing_inputs" => pack.interpretation["missing_inputs"]
      },
      "scope" => pack.scope,
      "research_plan" =>
        Enum.map(pack.research_plan, fn lane ->
          %{
            "lane" => lane["lane"],
            "purpose" => lane["purpose"],
            "status" => lane["status"],
            "safe_query_fingerprint" => fingerprint(lane["safe_query"])
          }
        end),
      "sources" => Enum.map(pack.sources, &simulation_context_source_json/1),
      "claims" =>
        Enum.map(pack.claims, fn claim ->
          %{
            "id" => claim["id"],
            "statement_fingerprint" => fingerprint(claim["statement"]),
            "grounding_class" => claim["grounding_class"],
            "source_id" => claim["source_id"],
            "confidence" => claim["confidence"],
            "influences" => claim["influences"],
            "instruction_flags" => claim["instruction_flags"]
          }
        end),
      "assumptions" =>
        Enum.map(pack.assumptions, fn assumption ->
          %{
            "id" => assumption["id"],
            "statement_fingerprint" => fingerprint(assumption["statement"]),
            "rationale" => assumption["rationale"],
            "visible" => assumption["visible"]
          }
        end),
      "gaps" =>
        Enum.map(pack.gaps, fn gap ->
          %{
            "id" => gap["id"],
            "kind" => gap["kind"],
            "lane" => gap["lane"],
            "source_id" => gap["source_id"],
            "statement_fingerprint" => fingerprint(gap["statement"])
          }
        end),
      "research_metadata" => pack.research_metadata,
      "historical_cutoff" => pack.historical_cutoff,
      "status" => pack.status,
      "confidence" => pack.confidence,
      "content_hash" => pack.content_hash,
      "inserted_at" => pack.inserted_at
    }
  end

  defp simulation_context_source_json(source) do
    %{
      "id" => source["id"],
      "kind" => source["kind"],
      "title" => source["title"],
      "uri" => safe_source_uri(source["uri"]),
      "uri_hash" => fingerprint(source["uri"]),
      "published_at" => source["published_at"],
      "content_hash" => source["content_hash"],
      "status" => source["status"],
      "instruction_flags" => source["instruction_flags"],
      "review_required" => source["review_required"],
      "excerpt_fingerprint" => fingerprint(source["excerpt"])
    }
  end

  defp simulation_context_research_run_json(run) do
    %{
      "id" => run.id,
      "workspace_id" => run.workspace_id,
      "simulation_id" => run.simulation_id,
      "simulation_version_id" => run.simulation_version_id,
      "context_pack_id" => run.context_pack_id,
      "provider" => run.provider,
      "status" => run.status,
      "input_snapshot" => run.input_snapshot,
      "planned_lanes" => run.planned_lanes,
      "completed_lanes" => run.completed_lanes,
      "failed_lanes" => run.failed_lanes,
      "failure_reason" => run.failure_reason,
      "started_at" => run.started_at,
      "completed_at" => run.completed_at,
      "inserted_at" => run.inserted_at,
      "updated_at" => run.updated_at
    }
  end

  defp simulation_population_model_json(model) do
    %{
      "id" => model.id,
      "workspace_id" => model.workspace_id,
      "simulation_id" => model.simulation_id,
      "simulation_version_id" => model.simulation_version_id,
      "context_pack_id" => model.context_pack_id,
      "created_by_user_id" => model.created_by_user_id,
      "version" => model.version,
      "schema_version" => model.schema_version,
      "compiler_version" => model.compiler_version,
      "seed" => model.seed,
      "population_size" => model.population_size,
      "agent_types" => Enum.map(model.agent_types, &audit_population_type/1),
      "archetypes" => Enum.map(model.archetypes, &audit_population_archetype/1),
      "conditional_distributions_fingerprint" => fingerprint(model.conditional_distributions),
      "relationship_rules" => model.relationship_rules,
      "representative_rules" => model.representative_rules,
      "imported_agent_count" => length(model.imported_agents),
      "imported_agents_fingerprint" => fingerprint(model.imported_agents),
      "imported_relationship_count" => length(model.imported_relationships),
      "imported_relationships_fingerprint" => fingerprint(model.imported_relationships),
      "import_summary" => audit_population_import_summary(model.import_summary),
      "compile_summary" => audit_population_compile_summary(model.compile_summary),
      "generation_metadata" =>
        Map.take(model.generation_metadata || %{}, [
          "route",
          "model_calls",
          "intended_use",
          "source_context_hash",
          "source_context_version",
          "sensitive_attributes_inferred",
          "protocol_version",
          "rebased_from_population_model_id"
        ]),
      "status" => model.status,
      "content_hash" => model.content_hash,
      "inserted_at" => model.inserted_at
    }
  end

  defp audit_population_type(type) do
    %{
      "id" => type["id"],
      "label_fingerprint" => fingerprint(type["label"]),
      "description_fingerprint" => fingerprint(type["description"]),
      "weight" => type["weight"],
      "attributes" =>
        Enum.map(type["attributes"] || [], fn attribute ->
          Map.take(attribute, [
            "key",
            "type",
            "min",
            "max",
            "sensitive",
            "source",
            "aggregate_only",
            "individual_exposure"
          ])
          |> Map.put("necessity_fingerprint", fingerprint(attribute["necessity"]))
          |> Map.put("lawful_basis_fingerprint", fingerprint(attribute["lawful_basis"]))
        end),
      "resources" => type["resources"],
      "actions" => type["actions"],
      "grounding" => type["grounding"]
    }
  end

  defp audit_population_archetype(archetype) do
    %{
      "id" => archetype["id"],
      "agent_type" => archetype["agent_type"],
      "weight" => archetype["weight"],
      "summary_fingerprint" => fingerprint(archetype["summary"]),
      "distributions_fingerprint" => fingerprint(archetype["distributions"]),
      "goals_fingerprint" => fingerprint(archetype["goals"]),
      "constraints_fingerprint" => fingerprint(archetype["constraints"]),
      "initial_state_fingerprint" => fingerprint(archetype["initial_state"]),
      "initial_resources_fingerprint" => fingerprint(archetype["initial_resources"]),
      "policy_id" => archetype["policy_id"],
      "memory_seeds_fingerprint" => fingerprint(archetype["memory_seeds"]),
      "grounding" => archetype["grounding"]
    }
  end

  defp audit_population_import_summary(summary) when is_map(summary) do
    summary
    |> Map.take([
      "format",
      "kind",
      "valid_count",
      "error_count",
      "content_hash",
      "total_imported_agent_count",
      "total_imported_relationship_count"
    ])
    |> Map.put("filename_fingerprint", fingerprint(summary["filename"]))
    |> Map.put("errors_fingerprint", fingerprint(summary["errors"] || []))
  end

  defp audit_population_import_summary(_summary), do: %{}

  defp audit_population_compile_summary(summary) when is_map(summary) do
    summary
    |> Map.drop(["representatives"])
    |> Map.put(
      "representatives_fingerprint",
      fingerprint(summary["representatives"] || [])
    )
  end

  defp audit_population_compile_summary(_summary), do: %{}

  defp simulation_persona_projection_json(projection) do
    %{
      "id" => projection.id,
      "workspace_id" => projection.workspace_id,
      "simulation_id" => projection.simulation_id,
      "simulation_version_id" => projection.simulation_version_id,
      "population_model_id" => projection.population_model_id,
      "created_by_user_id" => projection.created_by_user_id,
      "agent_id_fingerprint" => fingerprint(projection.agent_id),
      "archetype_id" => projection.archetype_id,
      "projection_fingerprint" => fingerprint(projection.projection),
      "prose_fingerprint" => fingerprint(projection.prose),
      "generated_by" => projection.generated_by,
      "generated_lazily" => projection.generated_lazily,
      "content_hash" => projection.content_hash,
      "inserted_at" => projection.inserted_at
    }
  end

  defp study_json(study) do
    %{
      "id" => study.id,
      "title" => study.title,
      "question" => study.question,
      "domain" => study.domain,
      "region" => study.region,
      "language" => study.language,
      "timeframe" => study.timeframe,
      "target_audience" => study.target_audience,
      "desired_outcomes" => study.desired_outcomes,
      "status" => study.status,
      "inserted_at" => study.inserted_at,
      "updated_at" => study.updated_at
    }
  end

  defp source_json(source) do
    %{
      "id" => source.id,
      "study_id" => source.study_id,
      "kind" => source.kind,
      "title" => source.title,
      "uri" => safe_source_uri(source.uri),
      "uri_hash" => fingerprint(source.uri),
      "content_hash" => source.content_hash,
      "metadata" => allowed_map(source.metadata, @source_metadata_keys),
      "metadata_fingerprint" => fingerprint(source.metadata),
      "pii_status" => source.pii_status,
      "access_policy" => allowed_map(source.access_policy, @source_access_policy_keys),
      "status" => source.status,
      "inserted_at" => source.inserted_at,
      "updated_at" => source.updated_at
    }
  end

  defp evidence_item_json(item) do
    %{
      "id" => item.id,
      "study_id" => item.study_id,
      "source_id" => item.source_id,
      "kind" => item.kind,
      "claim_hash" => fingerprint(item.claim),
      "normalized_claim_hash" => fingerprint(item.normalized_claim),
      "source_ref" => allowed_map(item.source_ref, @evidence_source_ref_keys),
      "grounding_level" => item.grounding_level,
      "reliability_score" => item.reliability_score,
      "relevance_score" => item.relevance_score,
      "freshness_score" => item.freshness_score,
      "confidence_score" => item.confidence_score,
      "simulation_impact" => item.simulation_impact,
      "tags" => item.tags,
      "metadata" => allowed_map(item.metadata, @evidence_metadata_keys),
      "inserted_at" => item.inserted_at,
      "updated_at" => item.updated_at
    }
  end

  defp context_pack_json(pack) do
    content = %{
      summary: pack.summary,
      key_findings: pack.key_findings,
      market_context: pack.market_context,
      behavioral_context: pack.behavioral_context,
      recent_context: pack.recent_context,
      regulatory_context: pack.regulatory_context,
      risks: pack.risks,
      assumptions: pack.assumptions,
      open_questions: pack.open_questions,
      simulation_implications: pack.simulation_implications
    }

    %{
      "id" => pack.id,
      "study_id" => pack.study_id,
      "version" => pack.version,
      "summary" => allowed_map(pack.summary, @context_summary_keys),
      "source_mix" => pack.source_mix,
      "section_counts" => %{
        "key_findings" => length(pack.key_findings),
        "market_context" => length(pack.market_context),
        "behavioral_context" => length(pack.behavioral_context),
        "recent_context" => length(pack.recent_context),
        "regulatory_context" => length(pack.regulatory_context),
        "risks" => length(pack.risks),
        "assumptions" => length(pack.assumptions),
        "open_questions" => length(pack.open_questions),
        "simulation_implications" => length(pack.simulation_implications)
      },
      "content_fingerprint" => fingerprint(content),
      "confidence" => pack.confidence,
      "generated_by_protocol_version" => pack.generated_by_protocol_version,
      "status" => pack.status,
      "inserted_at" => pack.inserted_at,
      "updated_at" => pack.updated_at
    }
  end

  defp persona_json(persona) do
    %{
      "id" => persona.id,
      "study_id" => persona.study_id,
      "name" => persona.name,
      "segment" => persona.segment,
      "distribution_weight" => persona.distribution_weight,
      "goals" => persona.goals,
      "frictions" => persona.frictions,
      "triggers" => persona.triggers,
      "trust_factors" => persona.trust_factors,
      "decision_style" => persona.decision_style,
      "likely_actions" => persona.likely_actions,
      "behavioral_parameters" => persona.behavioral_parameters,
      "evidence_refs" => persona.evidence_refs,
      "assumption_refs" => persona.assumption_refs,
      "grounding_mix" => persona.grounding_mix,
      "confidence" => persona.confidence,
      "editable_notes_hash" => fingerprint(persona.editable_notes),
      "version" => persona.version,
      "status" => persona.status,
      "inserted_at" => persona.inserted_at,
      "updated_at" => persona.updated_at
    }
  end

  defp action_pattern_json(pattern) do
    %{
      "id" => pattern.id,
      "study_id" => pattern.study_id,
      "name" => pattern.name,
      "persona_ids" => pattern.persona_ids,
      "condition" => pattern.condition,
      "interpretation" => pattern.interpretation,
      "motivation" => pattern.motivation,
      "likely_action" => pattern.likely_action,
      "base_probability" => pattern.base_probability,
      "blockers" => pattern.blockers,
      "amplifiers" => pattern.amplifiers,
      "state_updates" => pattern.state_updates,
      "grounding_level" => pattern.grounding_level,
      "evidence_refs" => pattern.evidence_refs,
      "assumption_refs" => pattern.assumption_refs,
      "confidence" => pattern.confidence,
      "executable_rule" => pattern.executable_rule,
      "version" => pattern.version,
      "status" => pattern.status,
      "inserted_at" => pattern.inserted_at,
      "updated_at" => pattern.updated_at
    }
  end

  defp scenario_json(scenario) do
    %{
      "id" => scenario.id,
      "study_id" => scenario.study_id,
      "variant_of_id" => scenario.variant_of_id,
      "name" => scenario.name,
      "description" => scenario.description,
      "forecast_horizon" => scenario.forecast_horizon,
      "events" => scenario.events,
      "available_actions" => scenario.available_actions,
      "success_metrics" => scenario.success_metrics,
      "constraints" => scenario.constraints,
      "metadata" => scenario.metadata,
      "inserted_at" => scenario.inserted_at,
      "updated_at" => scenario.updated_at
    }
  end

  defp simulation_run_json(run) do
    %{
      "id" => run.id,
      "study_id" => run.study_id,
      "scenario_id" => run.scenario_id,
      "context_pack_id" => run.context_pack_id,
      "mode" => run.mode,
      "agent_count" => run.agent_count,
      "rounds" => run.rounds,
      "seed" => run.seed,
      "status" => run.status,
      "budget_cap_usd" => decimal_json(run.budget_cap_usd),
      "actual_cost_usd" => decimal_json(run.actual_cost_usd),
      "decision_counts" => run.decision_counts,
      "aggregate_metrics" => run.aggregate_metrics,
      "input_fingerprint" => run.input_fingerprint,
      "execution_options" => run.execution_options,
      "confidence" => run.confidence,
      "started_at" => run.started_at,
      "completed_at" => run.completed_at,
      "inserted_at" => run.inserted_at,
      "updated_at" => run.updated_at
    }
  end

  defp snapshot_json(snapshot) do
    %{
      "id" => snapshot.id,
      "run_id" => snapshot.run_id,
      "tick" => snapshot.tick,
      "label" => snapshot.label,
      "clusters" => snapshot.clusters,
      "metrics" => snapshot.metrics,
      "decision_counts" => snapshot.decision_counts,
      "cost" => snapshot.cost,
      "insight_refs" => snapshot.insight_refs,
      "inserted_at" => snapshot.inserted_at
    }
  end

  defp outcome_event_json(event) do
    %{
      "id" => event.id,
      "run_id" => event.run_id,
      "tick" => event.tick,
      "persona_id" => event.persona_id,
      "action_pattern" => event.action_pattern,
      "action" => event.action,
      "probability" => event.probability,
      "confidence" => event.confidence,
      "state_delta" => event.state_delta,
      "metadata" => event.metadata,
      "inserted_at" => event.inserted_at
    }
  end

  defp forecast_report_json(report) do
    content = %{
      title: report.title,
      executive_summary: report.executive_summary,
      outcome_probabilities: report.outcome_probabilities,
      segment_reactions: report.segment_reactions,
      behavior_drivers: report.behavior_drivers,
      resistance_drivers: report.resistance_drivers,
      evidence_map: report.evidence_map,
      assumptions: report.assumptions,
      uncertainty: report.uncertainty,
      validation_recommendations: report.validation_recommendations,
      markdown_body: report.markdown_body
    }

    %{
      "id" => report.id,
      "run_id" => report.run_id,
      "study_id" => report.study_id,
      "title" => report.title,
      "executive_summary" => report.executive_summary,
      "outcome_probabilities" => report.outcome_probabilities,
      "segment_reactions" => report.segment_reactions,
      "behavior_drivers" => report.behavior_drivers,
      "resistance_drivers" => report.resistance_drivers,
      "evidence_map" => report.evidence_map,
      "assumptions" => report.assumptions,
      "uncertainty" => report.uncertainty,
      "validation_recommendations" => report.validation_recommendations,
      "content_fingerprint" => fingerprint(content),
      "inserted_at" => report.inserted_at,
      "updated_at" => report.updated_at
    }
  end

  defp calibration_json(record) do
    %{
      "id" => record.id,
      "study_id" => record.study_id,
      "run_id" => record.run_id,
      "metric" => record.metric,
      "forecast_value" => record.forecast_value,
      "actual_value" => record.actual_value,
      "delta" => record.delta,
      "note_hash" => fingerprint(record.note),
      "observed_at" => record.observed_at,
      "inserted_at" => record.inserted_at,
      "updated_at" => record.updated_at
    }
  end

  defp research_run_json(run) do
    %{
      "id" => run.id,
      "study_id" => run.study_id,
      "provider" => run.provider,
      "status" => run.status,
      "input_fingerprint" => SimulationRunner.input_fingerprint(run.input_snapshot),
      "source_count" => run.source_count,
      "failed_lanes" => run.failed_lanes,
      "failure_reason" => run.failure_reason,
      "started_at" => run.started_at,
      "completed_at" => run.completed_at,
      "inserted_at" => run.inserted_at,
      "updated_at" => run.updated_at
    }
  end

  defp map_records(records, mapper), do: Enum.map(records, mapper)

  defp allowed_map(value, keys) when is_map(value) do
    Map.take(value, keys)
  end

  defp allowed_map(_value, _keys), do: %{}

  defp fingerprint(nil), do: nil

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_source_uri(nil), do: nil

  defp safe_source_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) ->
        parsed
        |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp safe_source_uri(_value), do: nil

  defp decimal_json(nil), do: nil
  defp decimal_json(value), do: Decimal.to_string(value)

  defp loaded(value), do: if(Ecto.assoc_loaded?(value), do: value, else: [])
end
