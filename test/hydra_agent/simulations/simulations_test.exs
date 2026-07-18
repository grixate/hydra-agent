defmodule HydraAgent.SimulationsTest do
  use HydraAgent.DataCase, async: false

  import Ecto.Query
  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.Schemas.Study

  alias HydraAgent.Simulations.{
    Blueprints,
    BuildStage,
    Simulation,
    SimulationVersion
  }

  setup do
    workspace = workspace_fixture(%{name: "Studio", slug: "simulation-studio"})
    [general, decision_replay] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general, decision_replay: decision_replay}
  end

  test "one question creates a durable versioned draft and six build stages", %{
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
    assert simulation.status == "draft"
    assert simulation.active_version.version == 1
    assert simulation.active_version.blueprint_version_id == general.active_version.id
    assert simulation.active_version.execution_mode == "quick"
    assert simulation.active_version.population_size == 5_000
    assert byte_size(simulation.active_version.content_hash) == 64

    persisted = HydraAgent.Simulations.get_simulation_for_workspace!(workspace.id, simulation.id)
    assert persisted.question == attrs["question"]
    assert persisted.active_version.content_hash == simulation.active_version.content_hash

    assert Enum.map(HydraAgent.Simulations.list_build_stages(persisted), &{&1.stage, &1.status}) ==
             [
               {"understanding_question", "pending"},
               {"finding_context", "pending"},
               {"designing_population", "pending"},
               {"writing_rules", "pending"},
               {"checking_model", "pending"},
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
    assert copy.title == "Adoption test copy"
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
