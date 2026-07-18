defmodule HydraAgent.Simulations.BlueprintPackageTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias HydraAgent.Simulations.{
    BlueprintManifest,
    BlueprintPackage,
    BuiltInBlueprints
  }

  test "both built-ins export deterministically and preserve semantic content on import" do
    packages = BuiltInBlueprints.all()

    assert Enum.map(packages, & &1.manifest["id"]) == [
             "general-agent-simulation",
             "decision-replay"
           ]

    for package <- packages do
      assert {:ok, first} = BlueprintPackage.export(package)
      assert {:ok, second} = BlueprintPackage.export(package)
      assert first.binary == second.binary
      assert String.ends_with?(first.filename, ".hydra-blueprint")

      assert {:ok, imported} = BlueprintPackage.import(first.binary)
      assert imported.content_hash == package.content_hash
      assert imported.manifest["id"] == package.manifest["id"]

      assert Map.keys(imported.instructions) |> Enum.sort() ==
               ~w(agents report research simulation)

      assert map_size(imported.schemas) == 5
    end
  end

  test "rejects path traversal before extraction" do
    archive = zip!([{~c"blueprint/../escape.txt", "escape"}])

    assert {:error, %{code: :unsafe_path}} = BlueprintPackage.import(archive)
  end

  test "rejects symlinks and executable files even when they are optional" do
    symlink_archive = symlink_zip("blueprint/link", "target")
    assert {:error, %{code: :unsafe_file_type}} = BlueprintPackage.import(symlink_archive)

    entries = exported_entries(BuiltInBlueprints.general_agent_simulation())
    executable_archive = zip!(entries ++ [{~c"blueprint/examples/install.sh", "exit 0"}])
    assert {:error, %{code: :executable_file}} = BlueprintPackage.import(executable_archive)
  end

  test "rejects compressed and uncompressed size limit violations" do
    assert {:error, %{code: :archive_too_large}} =
             BlueprintPackage.import(:binary.copy(<<0>>, 2_000_001))

    oversized = :binary.copy("a", 2_000_001)
    archive = zip!([{~c"blueprint/README.md", oversized}])
    assert byte_size(archive) < 2_000_000
    assert {:error, %{code: :file_too_large}} = BlueprintPackage.import(archive)
  end

  test "verifies declared hashes and rejects external schema references" do
    package = BuiltInBlueprints.general_agent_simulation()
    entries = exported_entries(package)
    manifest = entry!(entries, "blueprint/blueprint.yaml") |> parse_manifest!()

    bad_hash_manifest =
      put_in(manifest, ["files", "README.md"], String.duplicate("0", 64))
      |> BlueprintManifest.encode()

    bad_hash_archive =
      entries
      |> replace_entry("blueprint/blueprint.yaml", bad_hash_manifest)
      |> zip!()

    assert {:error, %{code: :hash_mismatch, detail: "README.md"}} =
             BlueprintPackage.import(bad_hash_archive)

    schema_path = "blueprint/schemas/context-pack.schema.json"

    external_schema =
      entries
      |> entry!(schema_path)
      |> Jason.decode!()
      |> Map.put("$ref", "https://example.invalid/schema.json")
      |> Jason.encode!(pretty: true)

    unhashed_manifest = manifest |> Map.delete("files") |> BlueprintManifest.encode()

    external_ref_archive =
      entries
      |> replace_entry("blueprint/blueprint.yaml", unhashed_manifest)
      |> replace_entry(schema_path, external_schema)
      |> zip!()

    assert {:error, %{code: :unsafe_schema_reference, detail: "schemas/context-pack.schema.json"}} =
             BlueprintPackage.import(external_ref_archive)
  end

  test "ignores unknown inert optional files without changing semantic content" do
    package = BuiltInBlueprints.general_agent_simulation()
    entries = exported_entries(package)
    archive = zip!(entries ++ [{~c"blueprint/notes.txt", "Ignored portability note"}])

    assert {:ok, imported} = BlueprintPackage.import(archive)
    assert imported.content_hash == package.content_hash
    refute Map.has_key?(imported.examples, "notes.txt")
  end

  test "manifest validation rejects aliases and unsupported required capabilities" do
    assert {:error, %{code: :unsafe_yaml}} =
             BlueprintManifest.parse("id: &shared example\nname: *shared\n")

    package = BuiltInBlueprints.general_agent_simulation()
    manifest = put_in(package.manifest, ["capabilities", "build"], ["unbounded_agent_shell"])

    assert {:error, %{code: :invalid_manifest, detail: %{errors: errors}}} =
             BlueprintPackage.from_components(%{
               manifest: manifest,
               instructions: package.instructions,
               schemas: package.schemas,
               examples: package.examples,
               readme: package.readme
             })

    assert Enum.any?(errors, &(&1["code"] == "unsupported_capability"))
  end

  test "manifest validation rejects duplicate variables and invalid Hydra versions" do
    package = BuiltInBlueprints.general_agent_simulation()

    available =
      package.schemas
      |> Map.keys()
      |> Kernel.++(
        Enum.map(package.manifest["modules"], fn {_name, module} -> module["instructions"] end)
      )
      |> MapSet.new()

    duplicate_variables =
      Map.put(package.manifest, "variables", [
        %{"key" => "population_size", "type" => "integer"},
        %{"key" => "population_size", "type" => "integer"}
      ])

    invalid_compatibility =
      put_in(package.manifest, ["compatibility", "minimum_hydra_version"], "latest")

    assert {:error, duplicate_errors, _warnings} =
             BlueprintManifest.validate(duplicate_variables, available)

    assert Enum.any?(duplicate_errors, &(&1["code"] == "duplicate_key"))

    assert {:error, version_errors, _warnings} =
             BlueprintManifest.validate(invalid_compatibility, available)

    assert Enum.any?(
             version_errors,
             &(&1["path"] == "compatibility.minimum_hydra_version")
           )
  end

  defp exported_entries(package) do
    {:ok, export} = BlueprintPackage.export(package)
    {:ok, entries} = :zip.extract(export.binary, [:memory])
    entries
  end

  defp entry!(entries, path) do
    path = String.to_charlist(path)
    {^path, content} = Enum.find(entries, fn {name, _content} -> name == path end)
    content
  end

  defp replace_entry(entries, path, content) do
    path = String.to_charlist(path)

    Enum.map(entries, fn
      {^path, _old} -> {path, content}
      entry -> entry
    end)
  end

  defp parse_manifest!(yaml) do
    {:ok, manifest} = BlueprintManifest.parse(yaml)
    manifest
  end

  defp zip!(entries) do
    {:ok, {_name, binary}} = :zip.create(~c"test.hydra-blueprint", entries, [:memory])
    binary
  end

  defp symlink_zip(path, target) do
    crc = :erlang.crc32(target)
    size = byte_size(target)
    path_size = byte_size(path)

    local =
      <<0x04034B50::little-32, 20::little-16, 0::little-16, 0::little-16, 0::little-16,
        0::little-16, crc::little-32, size::little-32, size::little-32, path_size::little-16,
        0::little-16, path::binary, target::binary>>

    unix_symlink_mode = 0o120777 <<< 16

    central =
      <<0x02014B50::little-32, 0x0314::little-16, 20::little-16, 0::little-16, 0::little-16,
        0::little-16, 0::little-16, crc::little-32, size::little-32, size::little-32,
        path_size::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16,
        unix_symlink_mode::little-32, 0::little-32, path::binary>>

    <<local::binary, central::binary, 0x06054B50::little-32, 0::little-16, 0::little-16,
      1::little-16, 1::little-16, byte_size(central)::little-32, byte_size(local)::little-32,
      0::little-16>>
  end
end
