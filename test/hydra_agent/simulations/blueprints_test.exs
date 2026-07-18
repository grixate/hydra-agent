defmodule HydraAgent.Simulations.BlueprintsTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.Simulations.{Blueprint, BlueprintPackage, Blueprints, BlueprintVersion}

  setup do
    workspace = workspace_fixture()
    built_ins = Blueprints.ensure_builtins!()

    %{workspace: workspace, built_ins: built_ins}
  end

  test "provisions exactly the two idempotent system built-ins", %{workspace: workspace} do
    assert Enum.map(Blueprints.ensure_builtins!(), & &1.slug) == [
             "general-agent-simulation",
             "decision-replay"
           ]

    visible = Blueprints.list_blueprints(workspace.id)
    assert Enum.count(visible, & &1.built_in) == 2
    assert Enum.all?(visible, &(&1.active_version.version == "1.1.0"))
    assert Enum.all?(visible, &(is_nil(&1.workspace_id) and is_nil(&1.owner_user_id)))

    assert {:error, changeset} =
             %Blueprint{}
             |> Blueprint.create_changeset(%{
               slug: "third-built-in",
               name: %{"en" => "Third built in", "ru" => "Третий встроенный шаблон"},
               description: %{
                 "en" => "A built-in that the first release must reject.",
                 "ru" => "Встроенный шаблон, запрещённый в первом выпуске."
               },
               built_in: true,
               status: "active"
             })
             |> Repo.insert()

    assert "is invalid" in errors_on(changeset).slug
  end

  test "duplicates a built-in into a workspace and keeps the built-in read-only", %{
    workspace: workspace,
    built_ins: [general | _]
  } do
    assert {:error, :built_in_read_only} = Blueprints.archive_blueprint(general, nil)

    assert {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, nil)
    refute copy.built_in
    assert copy.workspace_id == workspace.id
    assert copy.source_blueprint_id == general.id
    assert copy.slug == "general-agent-simulation-copy"
    assert copy.active_version.instructions == general.active_version.instructions
    assert get_in(copy.name, ["en"]) == "General Agent Simulation copy"
  end

  test "publishes edits only as a higher immutable version", %{
    workspace: workspace,
    built_ins: [general | _]
  } do
    {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, nil)
    original = copy.active_version

    manifest = Map.put(original.manifest, "version", "1.1.0")

    instructions =
      Map.update!(original.instructions, "research", &(&1 <> "\nKeep the test bounded."))

    assert {:ok, updated} =
             Blueprints.create_version(copy, nil, %{
               manifest: manifest,
               instructions: instructions,
               schemas: original.schemas,
               examples: original.examples,
               readme: original.readme
             })

    assert updated.active_version.version == "1.1.0"
    assert updated.active_version.id != original.id
    assert Repo.get!(BlueprintVersion, original.id).instructions == original.instructions

    assert {:error, :version_must_increase} =
             Blueprints.create_version(updated, nil, %{
               manifest: manifest,
               instructions: instructions,
               schemas: original.schemas,
               examples: original.examples,
               readme: original.readme
             })
  end

  test "an exported custom Blueprint imports with the same semantic hash", %{
    workspace: workspace,
    built_ins: [general | _]
  } do
    target_workspace = workspace_fixture(%{name: "Target", slug: "target-workspace"})
    {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, nil)

    assert {:ok, export} = Blueprints.export_blueprint(copy)
    assert {:ok, imported} = Blueprints.import_blueprint(target_workspace, nil, export.binary)
    assert imported.active_version.content_hash == copy.active_version.content_hash
    assert imported.workspace_id == target_workspace.id
    assert imported.origin["kind"] == "imported"
  end

  test "Blueprint Test is provider-free, validated, and never publishes", %{
    workspace: workspace,
    built_ins: [general | _]
  } do
    {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, nil)
    version_count = Repo.aggregate(BlueprintVersion, :count)

    assert {:ok, result} = Blueprints.test_blueprint(copy)
    assert result.status == "passed"
    refute result.published
    assert result.preview.population_size == 3
    assert result.preview.rounds == 2
    assert result.preview.population_conserved
    assert result.cost.provider_calls == 0
    assert result.failures == []
    assert Repo.aggregate(BlueprintVersion, :count) == version_count
  end

  test "workspace roles and workspace isolation fail closed", %{
    workspace: workspace,
    built_ins: [general | _]
  } do
    other = workspace_fixture(%{name: "Other", slug: "other-workspace"})
    viewer = user_fixture()
    membership_fixture(viewer, workspace, "viewer")

    assert {:error, :forbidden} = Blueprints.duplicate_blueprint(general, workspace, viewer)

    researcher = user_fixture()
    membership_fixture(researcher, workspace, "researcher")
    assert {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, researcher)
    assert Blueprints.get_blueprint_for_workspace(other.id, copy.id) == nil
    assert Blueprints.get_blueprint_for_workspace(workspace.id, copy.id).id == copy.id
  end

  test "package validation errors do not create a Blueprint", %{workspace: workspace} do
    before_count = length(Blueprints.list_blueprints(workspace.id))

    assert {:error, %{code: :invalid_archive}} =
             Blueprints.import_blueprint(workspace, nil, "not a zip")

    assert length(Blueprints.list_blueprints(workspace.id)) == before_count
  end

  test "the exported package can be inspected independently of persistence", %{
    built_ins: [general | _]
  } do
    assert {:ok, export} = Blueprints.export_blueprint(general)
    assert {:ok, portable} = BlueprintPackage.import(export.binary)
    assert portable.manifest["name"]["ru"] == "Универсальная агентная симуляция"
  end
end
