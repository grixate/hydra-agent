defmodule HydraAgent.SimulationsTest do
  use HydraAgent.DataCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import Ecto.Query
  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.Schemas.Study

  alias HydraAgent.Simulations.{
    Blueprints,
    BuildStage,
    ContextPack,
    ContextResearchRun,
    PersonaProjection,
    PopulationModel,
    ScriptPreview,
    Simulation,
    SimulationScript,
    SimulationVersion,
    Workers.ContextResearchWorker
  }

  setup do
    workspace = workspace_fixture(%{name: "Studio", slug: "simulation-studio"})
    [general, decision_replay] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general, decision_replay: decision_replay}
  end

  test "one question creates a durable versioned build with a usable Context Pack", %{
    workspace: workspace,
    general: general
  } do
    attrs = %{
      "question" => "How might a new loyalty program change repeat purchasing?",
      "blueprint_id" => general.id,
      "locale" => "en",
      "execution_mode" => "quick",
      "population_size" => "5000",
      "inputs" => %{}
    }

    assert {:ok, simulation} = HydraAgent.Simulations.create_simulation(workspace, nil, attrs)
    assert simulation.status == "building"
    assert simulation.active_version.version == 1
    assert simulation.active_version.blueprint_version_id == general.active_version.id
    assert simulation.active_version.execution_mode == "quick"
    assert simulation.active_version.population_size == 5_000
    assert byte_size(simulation.active_version.content_hash) == 64
    assert simulation.active_context_pack.version == 1
    assert simulation.active_context_pack.status == "partial"
    assert simulation.active_context_pack.sources == []
    assert simulation.active_context_pack.research_metadata["retrieval_status"] == "not_run"
    assert byte_size(simulation.active_context_pack.content_hash) == 64
    assert simulation.active_population_model.version == 1
    assert simulation.active_population_model.population_size == 5_000
    assert simulation.active_population_model.compile_summary["population_size"] == 5_000
    assert simulation.active_population_model.generation_metadata["model_calls"] == 0
    assert simulation.active_script.version == 1
    assert simulation.active_script.status == "ready"
    assert simulation.active_script.generation_metadata["model_calls"] == 0
    assert simulation.active_script.preview.status == "passed"
    assert simulation.active_script.preview.rounds_completed == 2
    assert Repo.aggregate(ScriptPreview, :count) == 1
    assert Repo.aggregate(SimulationScript, :count) == 1
    assert Repo.aggregate(PersonaProjection, :count) == 0

    assert Enum.all?(simulation.active_context_pack.claims, fn claim ->
             claim["grounding_class"] == "model_prior"
           end)

    assert Enum.all?(simulation.active_context_pack.assumptions, fn assumption ->
             assumption["grounding_class"] == "assumption" and assumption["visible"]
           end)

    persisted = HydraAgent.Simulations.get_simulation_for_workspace!(workspace.id, simulation.id)
    assert persisted.question == attrs["question"]
    assert persisted.active_version.content_hash == simulation.active_version.content_hash

    assert Enum.map(HydraAgent.Simulations.list_build_stages(persisted), &{&1.stage, &1.status}) ==
             [
               {"understanding_question", "complete"},
               {"finding_context", "partial"},
               {"designing_population", "complete"},
               {"writing_rules", "complete"},
               {"checking_model", "complete"},
               {"preparing_run", "pending"}
             ]
  end

  test "optional notes, URLs, and inert files remain in the immutable input snapshot", %{
    workspace: workspace,
    general: general
  } do
    file_text = "segment,count\na,4"

    inputs = %{
      "notes" => "Use the current inventory limit.",
      "urls" => [%{"uri" => "https://example.com/context", "status" => "pending"}],
      "files" => [
        %{
          "filename" => "segments.csv",
          "extension" => ".csv",
          "media_type" => "text/csv",
          "size_bytes" => byte_size(file_text),
          "sha256" => sha256(file_text),
          "text" => file_text
        }
      ]
    }

    assert {:ok, simulation} =
             HydraAgent.Simulations.create_simulation(workspace, nil, %{
               "question" => "How could constrained inventory alter customer choices?",
               "blueprint_id" => general.id,
               "locale" => "en",
               "inputs" => inputs
             })

    assert simulation.active_version.inputs == inputs
    refute inspect(simulation.active_version.inputs) =~ System.tmp_dir!() <> "/"

    assert simulation.active_version.normalized_input["source_counts"] == %{
             "files" => 1,
             "notes" => 1,
             "urls" => 1
           }

    sources = simulation.active_context_pack.sources
    claims = simulation.active_context_pack.claims

    assert Enum.any?(sources, &(&1["kind"] == "user_data" and &1["status"] == "active"))
    assert Enum.any?(sources, &(&1["kind"] == "user_document" and &1["status"] == "active"))
    assert Enum.any?(sources, &(&1["kind"] == "external_source" and &1["status"] == "pending"))
    assert Enum.any?(claims, &(&1["grounding_class"] == "user_data"))
    assert Enum.any?(claims, &(&1["grounding_class"] == "user_document"))

    run = Repo.one!(ContextResearchRun)
    assert run.provider == "direct_sources"
    assert run.status == "queued"

    assert_enqueued(
      worker: ContextResearchWorker,
      args: %{"context_research_run_id" => run.id}
    )
  end

  test "the domain rejects tampered file metadata even outside the web boundary", %{
    workspace: workspace,
    general: general
  } do
    assert {:error, :invalid_file} =
             HydraAgent.Simulations.create_simulation(workspace, nil, %{
               "question" => "How might tampered input metadata be rejected?",
               "blueprint_id" => general.id,
               "inputs" => %{
                 "files" => [
                   %{
                     "filename" => "input.csv",
                     "extension" => ".csv",
                     "media_type" => "text/csv",
                     "size_bytes" => 3,
                     "sha256" => String.duplicate("0", 64),
                     "text" => "a,b"
                   }
                 ]
               }
             })

    assert Repo.aggregate(SimulationVersion, :count) == 0
  end

  test "equal semantic drafts have equal hashes and duplicating preserves provenance", %{
    workspace: workspace,
    general: general
  } do
    attrs = %{
      "title" => "Adoption test",
      "question" => "How could teams adopt a new internal planning system?",
      "blueprint_id" => general.id,
      "locale" => "en",
      "inputs" => %{}
    }

    assert {:ok, first} = HydraAgent.Simulations.create_simulation(workspace, nil, attrs)
    assert {:ok, second} = HydraAgent.Simulations.create_simulation(workspace, nil, attrs)
    assert first.active_version.content_hash == second.active_version.content_hash

    assert {:ok, copy} = HydraAgent.Simulations.duplicate_simulation(first, nil)
    assert copy.source_simulation_id == first.id
    assert copy.title == "Copy · Adoption test"
    assert copy.active_version.id != first.active_version.id
    assert copy.active_version.blueprint_version_id == first.active_version.blueprint_version_id
  end

  test "archiving hides a Simulation without changing its immutable version", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a queue policy alter service outcomes?",
        "blueprint_id" => general.id
      })

    version_id = simulation.active_version.id
    assert {:ok, archived} = HydraAgent.Simulations.archive_simulation(simulation, nil)
    assert archived.status == "archived"
    assert archived.archived_at
    assert HydraAgent.Simulations.list_simulations(workspace.id) == []
    assert Repo.get!(SimulationVersion, version_id).question == simulation.question
  end

  test "workspace roles, Blueprint scope, and execution flags fail closed", %{
    workspace: workspace,
    general: general
  } do
    other = workspace_fixture(%{name: "Other", slug: "simulation-other"})
    viewer = user_fixture()
    membership_fixture(viewer, workspace, "viewer")

    assert {:error, :forbidden} =
             HydraAgent.Simulations.create_simulation(workspace, viewer, %{
               "question" => "How might this viewer try to create a simulation?",
               "blueprint_id" => general.id
             })

    researcher = user_fixture()
    membership_fixture(researcher, workspace, "researcher")

    assert {:ok, simulation} =
             HydraAgent.Simulations.create_simulation(workspace, researcher, %{
               "question" => "How might a permitted researcher model a service queue?",
               "blueprint_id" => general.id
             })

    assert HydraAgent.Simulations.get_simulation_for_workspace(other.id, simulation.id) == nil

    assert {:error, :mode_disabled} =
             HydraAgent.Simulations.create_simulation(workspace, researcher, %{
               "question" => "How might a disabled deep mode behave safely?",
               "blueprint_id" => general.id,
               "execution_mode" => "deep"
             })
  end

  test "legacy studies remain visible through the additive adapter", %{workspace: workspace} do
    study =
      %Study{}
      |> Study.changeset(%{
        workspace_id: workspace.id,
        title: "Existing Decision Replay",
        question: "What did the team know before the decision?",
        status: "draft"
      })
      |> Repo.insert!()

    assert Enum.map(HydraAgent.Simulations.list_legacy_studies(workspace.id), & &1.id) == [
             study.id
           ]

    assert Repo.get!(Study, study.id).question == "What did the team know before the decision?"
  end

  test "Decision Replay enables strict publication-date handling at its historical cutoff", %{
    workspace: workspace,
    decision_replay: decision_replay
  } do
    assert {:ok, simulation} =
             HydraAgent.Simulations.create_simulation(workspace, nil, %{
               "question" => "What could the team have known before the launch decision?",
               "blueprint_id" => decision_replay.id,
               "historical_cutoff" => "2024-01-31"
             })

    assert simulation.active_version.normalized_input["strict_historical_cutoff"] == true
    assert simulation.active_context_pack.scope["strict_historical_cutoff"] == true
  end

  test "database triggers reject build-stage identity mutation", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable inputs protect exact replay?",
        "blueprint_id" => general.id
      })

    stage = List.first(HydraAgent.Simulations.list_build_stages(simulation))

    assert_raise Postgrex.Error, ~r/build stage identity is immutable/, fn ->
      BuildStage
      |> where([candidate], candidate.id == ^stage.id)
      |> Repo.update_all(set: [stage: "finding_context"])
    end
  end

  test "database triggers keep Simulation Versions immutable", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable inputs protect an exact replay?",
        "blueprint_id" => general.id
      })

    assert_raise Postgrex.Error, ~r/simulation versions are immutable/, fn ->
      SimulationVersion
      |> where([version], version.id == ^simulation.active_version.id)
      |> Repo.update_all(set: [question: "Mutated question"])
    end
  end

  test "database triggers keep Context Packs immutable", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable context preserve exact provenance?",
        "blueprint_id" => general.id
      })

    assert_raise Postgrex.Error, ~r/simulation context packs are immutable/, fn ->
      ContextPack
      |> where([pack], pack.id == ^simulation.active_context_pack.id)
      |> Repo.update_all(set: [status: "ready"])
    end
  end

  test "database triggers keep Population Models immutable", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable population state preserve exact replay?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    assert_raise Postgrex.Error, ~r/simulation population models are immutable/, fn ->
      PopulationModel
      |> where([model], model.id == ^simulation.active_population_model.id)
      |> Repo.update_all(set: [status: "partial"])
    end
  end

  test "database triggers keep Persona projections immutable", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable readable projections preserve provenance?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    [representative | _] = simulation.active_population_model.compile_summary["representatives"]

    assert {:ok, %{projection: projection, created: true}} =
             HydraAgent.Simulations.generate_persona_projection(
               simulation,
               representative["agent_id"],
               nil
             )

    assert_raise Postgrex.Error, ~r/simulation persona projections are immutable/, fn ->
      PersonaProjection
      |> where([candidate], candidate.id == ^projection.id)
      |> Repo.update_all(set: [prose: "mutated"])
    end
  end

  test "database triggers keep Scripts and miniature previews immutable", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might immutable rules preserve a repeatable miniature run?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    assert_raise Postgrex.Error, ~r/simulation scripts are immutable/, fn ->
      SimulationScript
      |> where([script], script.id == ^simulation.active_script.id)
      |> Repo.update_all(set: [status: "blocked"])
    end

    assert_raise Postgrex.Error, ~r/simulation script previews are immutable/, fn ->
      ScriptPreview
      |> where([preview], preview.id == ^simulation.active_script.preview.id)
      |> Repo.update_all(set: [status: "failed"])
    end
  end

  test "an active Script requires matching durable preview evidence", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How should activation fail when preview evidence is missing?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    source = simulation.active_script

    unpreviewed =
      %SimulationScript{}
      |> SimulationScript.changeset(%{
        workspace_id: source.workspace_id,
        simulation_id: source.simulation_id,
        simulation_version_id: source.simulation_version_id,
        context_pack_id: source.context_pack_id,
        population_model_id: source.population_model_id,
        version: 2,
        schema_version: source.schema_version,
        compiler_version: source.compiler_version,
        script: source.script,
        validation_report: source.validation_report,
        generation_metadata: source.generation_metadata,
        status: "ready",
        content_hash: String.duplicate("e", 64)
      })
      |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/active script requires matching preview evidence/, fn ->
      Simulation
      |> where([candidate], candidate.id == ^simulation.id)
      |> Repo.update_all(set: [active_script_id: unpreviewed.id])
    end
  end

  test "Script scope integrity rejects a Population Model from another Simulation", %{
    workspace: workspace,
    general: general
  } do
    {:ok, first} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might the first Script remain attached to its own Simulation?",
        "blueprint_id" => general.id,
        "population_size" => 20
      })

    {:ok, second} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might the second Script remain attached to its own Simulation?",
        "blueprint_id" => general.id,
        "population_size" => 20
      })

    source = second.active_script

    assert_raise Postgrex.Error, ~r/script scope does not match its population model/, fn ->
      %SimulationScript{}
      |> SimulationScript.changeset(%{
        workspace_id: first.workspace_id,
        simulation_id: first.id,
        simulation_version_id: first.active_version_id,
        context_pack_id: first.active_context_pack_id,
        population_model_id: second.active_population_model_id,
        version: 2,
        schema_version: source.schema_version,
        compiler_version: source.compiler_version,
        script: source.script,
        validation_report: source.validation_report,
        generation_metadata: source.generation_metadata,
        status: source.status,
        content_hash: String.duplicate("f", 64)
      })
      |> Repo.insert!()
    end
  end

  test "source exclusion creates a new immutable Pack and resets downstream build stages", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might service notes influence a queue simulation?",
        "blueprint_id" => general.id,
        "inputs" => %{"notes" => "Peak-hour demand is twice the daily average."}
      })

    first_pack = simulation.active_context_pack
    [source] = Enum.filter(first_pack.sources, &(&1["kind"] == "user_data"))

    stage =
      simulation
      |> HydraAgent.Simulations.list_build_stages()
      |> Enum.find(&(&1.stage == "designing_population"))

    now = DateTime.utc_now()

    stage
    |> BuildStage.changeset(%{status: "complete", started_at: now, completed_at: now})
    |> Repo.update!()

    assert {:ok, result} =
             HydraAgent.Simulations.exclude_context_source(simulation, source["id"], nil)

    assert result.created
    assert result.context_pack.version == 2
    refute Enum.any?(result.context_pack.sources, &(&1["id"] == source["id"]))
    refute Enum.any?(result.context_pack.claims, &(&1["source_id"] == source["id"]))
    assert result.context_pack.research_metadata["rebuild_required"]
    assert source["id"] in result.context_pack.research_metadata["excluded_source_ids"]

    assert Repo.get!(ContextPack, first_pack.id).sources == first_pack.sources

    assert simulation
           |> HydraAgent.Simulations.list_build_stages()
           |> Enum.find(&(&1.stage == "designing_population"))
           |> Map.fetch!(:status) == "complete"

    refreshed_population = result.simulation.active_population_model
    assert refreshed_population.version == 2
    assert refreshed_population.context_pack_id == result.context_pack.id
    assert refreshed_population.compile_summary["population_size"] == 5_000
    assert result.script.version == 2
    assert result.script.context_pack_id == result.context_pack.id
    assert result.script.population_model_id == refreshed_population.id
    assert result.preview.status == "passed"
    assert result.simulation.active_script.id == result.script.id

    assert {:error, :context_source_not_found} =
             HydraAgent.Simulations.exclude_context_source(
               result.simulation,
               "source-does-not-exist",
               nil
             )

    assert {:ok, %{created: false, context_pack: rebuilt}} =
             HydraAgent.Simulations.build_context_pack(result.simulation, nil)

    assert rebuilt.id == result.context_pack.id
    refute Enum.any?(rebuilt.sources, &(&1["id"] == source["id"]))
  end

  test "row imports, attribute removal, and readable projections create immutable versions", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a bounded participant group respond to a service change?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    type_id = hd(simulation.active_population_model.agent_types)["id"]

    csv = """
    id,type,attribute_imported_signal
    supplied-1,#{type_id},0.8
    supplied-2,#{type_id},0.2
    invalid id,#{type_id},private-value-that-must-not-appear-in-errors
    """

    assert {:ok, imported} =
             HydraAgent.Simulations.import_population(
               simulation,
               nil,
               "agents.csv",
               csv
             )

    imported_model = imported.population_model
    assert imported.created
    assert imported_model.version == 2
    assert imported_model.status == "partial"
    assert length(imported_model.imported_agents) == 2
    assert imported_model.compile_summary["population_size"] == 50
    assert imported_model.compile_summary["imported_agent_count"] == 2
    assert imported.import["error_count"] == 1
    refute inspect(imported.import["errors"]) =~ "private-value-that-must-not-appear"
    assert imported.script.version == 2
    assert imported.script.population_model_id == imported_model.id
    assert imported.preview.status == "passed"

    assert {:ok, removed} =
             HydraAgent.Simulations.exclude_population_attribute(
               imported.simulation,
               type_id,
               "imported_signal",
               nil
             )

    assert removed.population_model.version == 3
    assert removed.script.version == 3
    assert removed.script.population_model_id == removed.population_model.id
    assert removed.preview.status == "passed"

    refute Enum.any?(
             Enum.find(removed.population_model.agent_types, &(&1["id"] == type_id))[
               "attributes"
             ],
             &(&1["key"] == "imported_signal")
           )

    [representative | _] = removed.population_model.compile_summary["representatives"]
    assert Repo.aggregate(PersonaProjection, :count) == 0

    assert {:ok, %{projection: projection, created: true}} =
             HydraAgent.Simulations.generate_persona_projection(
               removed.simulation,
               representative["agent_id"],
               nil
             )

    assert projection.generated_lazily
    assert projection.generated_by == "deterministic"
    assert projection.prose =~ "not a biography"

    assert {:ok, %{projection: same_projection, created: false}} =
             HydraAgent.Simulations.generate_persona_projection(
               removed.simulation,
               representative["agent_id"],
               nil
             )

    assert same_projection.id == projection.id
  end

  test "manual Script rebuild is content-addressed and idempotent", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might stable rules make Script rebuilding predictable?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    assert {:ok, %{created: false, script: script, preview: preview}} =
             HydraAgent.Simulations.build_simulation_script(simulation, nil)

    assert script.id == simulation.active_script.id
    assert preview.id == simulation.active_script.preview.id
    assert Repo.aggregate(SimulationScript, :count) == 1
    assert Repo.aggregate(ScriptPreview, :count) == 1
  end

  test "a custom JSON Population Model survives Context Pack rebasing", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might supplied service evidence influence a custom population?",
        "blueprint_id" => general.id,
        "population_size" => 50,
        "inputs" => %{"notes" => "A supplied operating constraint is active."}
      })

    [source] =
      Enum.filter(simulation.active_context_pack.sources, &(&1["kind"] == "user_data"))

    custom_contract =
      simulation.active_population_model
      |> PopulationModel.contract()
      |> update_in(["agent_types", Access.at(0), "label"], fn _label -> "Custom cohort" end)
      |> Map.put("hydra_population_model", 1)

    assert {:ok, imported} =
             HydraAgent.Simulations.import_population(
               simulation,
               nil,
               "custom-population.json",
               Jason.encode!(custom_contract)
             )

    assert imported.population_model.generation_metadata["route"] == "population_model_import"
    assert hd(imported.population_model.agent_types)["label"] == "Custom cohort"

    assert {:ok, unchanged} =
             HydraAgent.Simulations.build_population_model(imported.simulation, nil)

    refute unchanged.created
    assert unchanged.population_model.id == imported.population_model.id
    assert hd(unchanged.population_model.agent_types)["label"] == "Custom cohort"

    assert {:ok, rebased} =
             HydraAgent.Simulations.exclude_context_source(
               imported.simulation,
               source["id"],
               nil
             )

    assert rebased.context_pack.version == 2
    assert rebased.population_model.version == 3
    assert rebased.population_model.context_pack_id == rebased.context_pack.id
    assert rebased.population_model.generation_metadata["route"] == "population_model_import"
    assert hd(rebased.population_model.agent_types)["label"] == "Custom cohort"
    assert rebased.population_model.compile_summary["population_size"] == 50

    allowed_grounding =
      (rebased.context_pack.sources ++
         rebased.context_pack.claims ++
         rebased.context_pack.assumptions)
      |> MapSet.new(& &1["id"])

    assert Enum.all?(rebased.population_model.archetypes, fn archetype ->
             archetype["grounding"] != [] and
               Enum.all?(archetype["grounding"], &MapSet.member?(allowed_grounding, &1))
           end)
  end

  test "bounded mock research completes four lanes and activates attributable sources", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might teams adopt a new coordination practice?",
        "blueprint_id" => general.id
      })

    assert {:ok, %{run: run, queued: true}} =
             HydraAgent.Simulations.queue_context_research(simulation, nil, "mock")

    assert_enqueued(
      worker: ContextResearchWorker,
      args: %{"context_research_run_id" => run.id}
    )

    assert :ok =
             perform_job(ContextResearchWorker, %{"context_research_run_id" => run.id})

    completed = Repo.reload!(run)
    refreshed = HydraAgent.Simulations.get_simulation_for_workspace!(workspace.id, simulation.id)

    assert completed.status == "completed"
    assert completed.planned_lanes == 4
    assert completed.completed_lanes == 4
    assert completed.failed_lanes == 0
    assert completed.context_pack_id == refreshed.active_context_pack_id
    assert refreshed.active_context_pack.version == 2
    assert refreshed.active_context_pack.status == "ready"
    assert refreshed.active_context_pack.research_metadata["provider_calls"] == 4

    assert Enum.all?(refreshed.active_context_pack.sources, fn source ->
             source["kind"] == "external_source" and
               String.starts_with?(source["uri"], "https://") and
               source["title"] != ""
           end)

    assert Enum.any?(refreshed.active_context_pack.claims, fn claim ->
             claim["grounding_class"] == "external_source" and
               is_binary(claim["source_id"])
           end)

    assert {:ok, %{created: false, context_pack: unchanged}} =
             HydraAgent.Simulations.build_context_pack(refreshed, nil)

    assert unchanged.id == refreshed.active_context_pack.id
  end

  test "database triggers reject cross-workspace Simulation provenance", %{
    workspace: workspace,
    general: general
  } do
    other = workspace_fixture(%{name: "Provenance Other", slug: "provenance-other"})

    {:ok, source} =
      HydraAgent.Simulations.create_simulation(other, nil, %{
        "question" => "How might this source stay inside its workspace?",
        "blueprint_id" => general.id
      })

    assert_raise Postgrex.Error, ~r/source simulation must belong to the same workspace/, fn ->
      %Simulation{}
      |> Simulation.creation_changeset(%{
        workspace_id: workspace.id,
        selected_blueprint_id: general.id,
        source_simulation_id: source.id,
        title: "Invalid provenance",
        question: "How might cross-workspace provenance be rejected safely?",
        locale: "en",
        status: "draft"
      })
      |> Repo.insert!()
    end
  end

  test "database triggers reject an unauthorized version author", %{
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might version authorship stay workspace scoped?",
        "blueprint_id" => general.id
      })

    other = workspace_fixture(%{name: "Author Other", slug: "author-other"})
    outsider = user_fixture()
    membership_fixture(outsider, other, "researcher")
    original = simulation.active_version

    assert_raise Postgrex.Error, ~r/version author is not authorized/, fn ->
      %SimulationVersion{}
      |> SimulationVersion.changeset(%{
        workspace_id: workspace.id,
        simulation_id: simulation.id,
        blueprint_version_id: general.active_version.id,
        created_by_user_id: outsider.id,
        version: 2,
        title: original.title,
        question: original.question,
        locale: original.locale,
        normalized_input: original.normalized_input,
        inputs: original.inputs,
        instruction_overrides: original.instruction_overrides,
        research_settings: original.research_settings,
        population_size: original.population_size,
        execution_mode: original.execution_mode,
        budget_preset: original.budget_preset,
        model_routes: original.model_routes,
        content_hash: String.duplicate("f", 64)
      })
      |> Repo.insert!()
    end
  end

  defp sha256(content) do
    content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
