defmodule HydraAgent.Simulations.PortabilityTest do
  use HydraAgent.DataCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Repo, Simulations}

  alias HydraAgent.Simulations.{
    Blueprints,
    ContextPack,
    Engine,
    ManualExternalModel,
    PopulationModel,
    PortableArchive,
    Simulation,
    SimulationPack,
    SimulationScript
  }

  setup do
    workspace = workspace_fixture(%{name: "Portable", slug: "portable-simulations"})
    [general, _decision] = Blueprints.ensure_builtins!()

    %{workspace: workspace, general: general}
  end

  describe "portable archive boundary" do
    test "creates deterministic archives and verifies their manifest" do
      files = %{"README.md" => "Portable\n", "data.json" => ~s({"safe":true}\n)}
      manifest = %{"format_version" => 1, "privacy" => %{"raw_sources" => "excluded"}}

      assert {:ok, first} =
               PortableArchive.create(:simpack, files, manifest, "test.hydra-simpack")

      assert {:ok, second} =
               PortableArchive.create(:simpack, files, manifest, "test.hydra-simpack")

      assert first.binary == second.binary
      assert first.content_hash == second.content_hash

      assert {:ok, imported} = PortableArchive.import(:simpack, first.binary)
      assert imported.files == files
      assert imported.content_hash == first.content_hash
    end

    test "rejects traversal, executable files, oversized files, and changed payloads" do
      traversal = raw_zip([{"hydra-simpack/../escape.json", "{}", 0o644}])
      assert {:error, %{code: :unsafe_path}} = PortableArchive.import(:simpack, traversal)

      executable = raw_zip([{"hydra-simpack/payload.sh", "echo unsafe", 0o644}])
      assert {:error, %{code: :executable_file}} = PortableArchive.import(:simpack, executable)

      assert {:error, %{code: :file_too_large}} =
               PortableArchive.create(
                 :simpack,
                 %{"large.json" => String.duplicate("x", 32_000_001)},
                 %{"format_version" => 1},
                 "large.hydra-simpack"
               )

      assert {:ok, export} =
               PortableArchive.create(
                 :simpack,
                 %{"data.json" => "original"},
                 %{"format_version" => 1},
                 "changed.hydra-simpack"
               )

      changed = replace_zip_entry(export.binary, "hydra-simpack/data.json", "changed")

      assert {:error, %{code: :hash_mismatch, detail: "data.json"}} =
               PortableArchive.import(:simpack, changed)
    end
  end

  describe "Simulation Packs" do
    test "exports deterministically, excludes raw sources by default, and imports across workspaces",
         %{workspace: workspace, general: general} do
      simulation =
        simulation_fixture(workspace, general, %{
          "inputs" => %{
            "notes" => "Private launch notes",
            "urls" => [%{"uri" => "https://example.com/private", "status" => "pending"}],
            "files" => [input_file("cohorts.csv", "segment,count\na,8")]
          }
        })

      assert {:ok, first} = Simulations.export_simulation_pack(simulation)
      assert {:ok, second} = Simulations.export_simulation_pack(simulation)
      assert first.binary == second.binary
      assert String.ends_with?(first.filename, ".hydra-simpack")

      assert {:ok, archive} = PortableArchive.import(:simpack, first.binary)
      refute Map.has_key?(archive.files, "raw-sources.json")
      refute first.binary =~ "Private launch notes"
      assert archive.manifest["privacy"]["raw_sources"] == "excluded"

      destination = workspace_fixture(%{name: "Destination", slug: "portable-destination"})

      assert {:ok, result} = Simulations.import_simulation_pack(destination, nil, first.binary)
      imported = result.simulation

      assert imported.workspace_id == destination.id
      assert imported.id != simulation.id
      assert imported.status == "ready_to_run"
      assert imported.active_version.inputs == %{"notes" => nil, "urls" => [], "files" => []}
      assert imported.active_version.population_size == simulation.active_version.population_size
      assert imported.active_script.preview.status == "passed"

      assert get_in(imported.active_version.normalized_input, ["portable_origin", "artifact_hash"]) ==
               first.content_hash

      assert "raw_sources_excluded" in result.warnings
      assert "budget_repriced_for_destination" in result.warnings
    end

    test "raw sources are explicit and redaction always excludes them", %{
      workspace: workspace,
      general: general
    } do
      email = "alex.person@example.com"

      simulation =
        simulation_fixture(workspace, general, %{
          "inputs" => %{
            "notes" => "Interview with #{email}",
            "urls" => [],
            "files" => [input_file("#{email}.csv", "email,choice\n#{email},yes")]
          }
        })

      assert {:ok, raw} =
               Simulations.export_simulation_pack(simulation, include_raw_sources: true)

      assert {:ok, raw_archive} = PortableArchive.import(:simpack, raw.binary)
      assert Map.has_key?(raw_archive.files, "raw-sources.json")
      assert raw_archive.files["raw-sources.json"] =~ email

      assert {:ok, redacted} =
               Simulations.export_simulation_pack(simulation,
                 include_raw_sources: true,
                 redact_identities: true,
                 include_provider_details: false
               )

      assert {:ok, redacted_archive} = PortableArchive.import(:simpack, redacted.binary)
      refute Map.has_key?(redacted_archive.files, "raw-sources.json")
      refute redacted.binary =~ email
      assert {:ok, redacted_pack} = SimulationPack.import(redacted.binary)
      assert redacted_pack.privacy["identities"] == "redacted"

      assert redacted_archive.manifest["privacy"] == %{
               "identities" => "redacted",
               "provider_details" => "omitted",
               "raw_sources" => "excluded",
               "redaction_version" => "hydra-redaction/v1"
             }
    end

    test "unsupported formats and component tampering fail with actionable errors", %{
      workspace: workspace,
      general: general
    } do
      assert {:ok, unsupported} =
               PortableArchive.create(
                 :simpack,
                 %{"README.md" => "future"},
                 %{"format_version" => 99},
                 "future.hydra-simpack"
               )

      assert {:error, %{code: :unsupported_format_version, message: message}} =
               SimulationPack.import(unsupported.binary)

      assert message =~ "Upgrade Hydra or re-export"

      simulation = simulation_fixture(workspace, general)
      assert {:ok, export} = Simulations.export_simulation_pack(simulation)
      assert {:ok, archive} = PortableArchive.import(:simpack, export.binary)

      population = Jason.decode!(archive.files["population-model.json"])
      changed = put_in(population, ["population_size"], population["population_size"] + 1)

      files = Map.put(archive.files, "population-model.json", PortableArchive.json(changed))

      manifest =
        archive.manifest
        |> Map.drop(["format", "files", "content_hash"])

      assert {:ok, repacked} =
               PortableArchive.create(:simpack, files, manifest, "tampered.hydra-simpack")

      assert {:error, %{code: :component_hash_mismatch, detail: :population}} =
               SimulationPack.import(repacked.binary)

      assert Repo.aggregate(Simulation, :count) == 1
    end

    test "rejects undeclared files, invalid privacy claims, and forged preview results", %{
      workspace: workspace,
      general: general
    } do
      simulation = simulation_fixture(workspace, general)
      assert {:ok, export} = Simulations.export_simulation_pack(simulation)
      assert {:ok, archive} = PortableArchive.import(:simpack, export.binary)

      assert {:ok, unknown_file} =
               repackage(
                 :simpack,
                 archive,
                 Map.put(archive.files, "undeclared.json", "{}\n")
               )

      assert {:error, %{code: :unexpected_files, detail: ["undeclared.json"]}} =
               SimulationPack.import(unknown_file.binary)

      invalid_privacy = put_in(archive.manifest, ["privacy", "identities"], "anonymish")
      assert {:ok, invalid_privacy} = repackage(:simpack, archive, archive.files, invalid_privacy)

      assert {:error, %{code: :invalid_privacy_manifest}} =
               SimulationPack.import(invalid_privacy.binary)

      preview =
        archive.files["preview.json"]
        |> Jason.decode!()
        |> put_in(["summary", "forged"], true)

      files = Map.put(archive.files, "preview.json", PortableArchive.json(preview))
      assert {:ok, forged_preview} = repackage(:simpack, archive, files)

      assert {:error, %{code: :preview_hash_mismatch}} =
               SimulationPack.import(forged_preview.binary)
    end
  end

  describe "Run Packs" do
    test "exports a deterministic, inspectable audit record without snapshots", %{
      workspace: workspace,
      general: general
    } do
      simulation = simulation_fixture(workspace, general, %{"population_size" => "36"})
      assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
      assert {:ok, _record} = Engine.execute(record.id)
      record = Simulations.get_simulation_run_record!(record.id)

      assert {:ok, first} =
               Simulations.export_run_pack(record,
                 include_model_rationales: false,
                 include_provider_details: false
               )

      assert {:ok, second} =
               Simulations.export_run_pack(record,
                 include_model_rationales: false,
                 include_provider_details: false
               )

      assert first.binary == second.binary
      assert String.ends_with?(first.filename, ".hydra-run")

      assert {:ok, inspected} = Simulations.inspect_run_pack(first.binary)
      assert inspected.run["status"] == "completed"
      assert inspected.run["result_hash"] == record.result_hash
      assert inspected.analysis["content_hash"] =~ ~r/^[a-f0-9]{64}$/
      assert inspected.privacy["snapshots"] == "excluded"
      assert inspected.privacy["model_rationales"] == "omitted"
      assert inspected.privacy["provider_details"] == "omitted"

      assert {:ok, archive} = PortableArchive.import(:run, first.binary)
      refute Enum.any?(Map.keys(archive.files), &String.contains?(&1, "snapshot"))
      assert Map.has_key?(archive.files, "events.jsonl")
      assert Map.has_key?(archive.files, "decisions.json")
      assert Map.has_key?(archive.files, "transactions.jsonl")
      assert Map.has_key?(archive.files, "usage.json")
    end

    test "rejects a repackaged Analysis whose semantic hash is stale", %{
      workspace: workspace,
      general: general
    } do
      simulation = simulation_fixture(workspace, general, %{"population_size" => "36"})
      assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
      assert {:ok, _record} = Engine.execute(record.id)
      record = Simulations.get_simulation_run_record!(record.id)

      assert {:ok, export} = Simulations.export_run_pack(record)
      assert {:ok, archive} = PortableArchive.import(:run, export.binary)

      analysis =
        archive.files["analysis.json"]
        |> Jason.decode!()
        |> Map.put("limitations", ["forged after export"])

      files = Map.put(archive.files, "analysis.json", PortableArchive.json(analysis))
      assert {:ok, forged_analysis} = repackage(:run, archive, files)

      assert {:error, %{code: :analysis_hash_mismatch}} =
               Simulations.inspect_run_pack(forged_analysis.binary)
    end
  end

  describe "manual external-model workflow" do
    test "exports exact lineage and imports schema-valid artifacts atomically", %{
      workspace: workspace,
      general: general
    } do
      simulation = simulation_fixture(workspace, general, %{"population_size" => "36"})

      assert {:ok, request_export} = Simulations.export_manual_external_request(simulation)
      request = Jason.decode!(request_export.binary)

      assert request["privacy"]["raw_sources"] == "excluded"
      assert request["simulation_version_hash"] == simulation.active_version.content_hash
      assert Enum.map(request["modules"], & &1["module"]) == ~w(research agents simulation)

      bundle = manual_bundle(simulation, request)

      before = %{
        context: Repo.aggregate(ContextPack, :count),
        population: Repo.aggregate(PopulationModel, :count),
        script: Repo.aggregate(SimulationScript, :count)
      }

      assert {:ok, result} =
               Simulations.import_manual_external_artifacts(
                 simulation,
                 nil,
                 Jason.encode!(bundle)
               )

      assert result.context_pack.version == simulation.active_context_pack.version + 1
      assert result.population_model.version == simulation.active_population_model.version + 1
      assert result.script.version == simulation.active_script.version + 1
      assert result.preview.status == "passed"

      assert result.context_pack.research_metadata["generation_route"] ==
               "manual_external_model"

      assert result.population_model.generation_metadata["route"] ==
               "manual_external_model"

      assert Repo.aggregate(ContextPack, :count) == before.context + 1
      assert Repo.aggregate(PopulationModel, :count) == before.population + 1
      assert Repo.aggregate(SimulationScript, :count) == before.script + 1
    end

    test "stale lineage and invalid JSON fail without creating partial artifacts", %{
      workspace: workspace,
      general: general
    } do
      simulation = simulation_fixture(workspace, general, %{"population_size" => "36"})
      assert {:ok, request_export} = Simulations.export_manual_external_request(simulation)
      request = Jason.decode!(request_export.binary)
      bundle = manual_bundle(simulation, request)

      counts = artifact_counts()

      stale = Map.put(bundle, "simulation_version_hash", String.duplicate("0", 64))

      assert {:error, %{code: :stale_manual_request, message: message}} =
               Simulations.import_manual_external_artifacts(simulation, nil, Jason.encode!(stale))

      assert message =~ "Export a new"
      assert artifact_counts() == counts

      assert {:error, %{code: :invalid_json}} =
               ManualExternalModel.parse("{not-json")

      assert artifact_counts() == counts
    end
  end

  defp simulation_fixture(workspace, blueprint, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "title" => "Portable launch model",
          "question" => "How might a bounded intervention change participant behavior?",
          "blueprint_id" => blueprint.id,
          "locale" => "en",
          "execution_mode" => "quick",
          "population_size" => "48",
          "horizon" => "3 rounds",
          "inputs" => %{}
        },
        overrides
      )

    assert {:ok, simulation} = Simulations.create_simulation(workspace, nil, attrs)
    simulation
  end

  defp input_file(filename, text) do
    %{
      "filename" => filename,
      "extension" => Path.extname(filename),
      "media_type" => "text/csv",
      "size_bytes" => byte_size(text),
      "sha256" => :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
      "text" => text
    }
  end

  defp manual_bundle(simulation, request) do
    %{
      "hydra_manual_artifacts" => 1,
      "simulation_version_hash" => request["simulation_version_hash"],
      "blueprint_version_hash" => request["blueprint"]["content_hash"],
      "base_artifact_hashes" => request["base_artifact_hashes"],
      "context_pack" => ContextPack.schema_payload(simulation.active_context_pack),
      "population_model" =>
        simulation.active_population_model
        |> PopulationModel.contract()
        |> PopulationModel.schema_payload(),
      "simulation_script" => simulation.active_script.script
    }
  end

  defp artifact_counts do
    %{
      context: Repo.aggregate(ContextPack, :count),
      population: Repo.aggregate(PopulationModel, :count),
      script: Repo.aggregate(SimulationScript, :count)
    }
  end

  defp raw_zip(entries) do
    entries =
      Enum.map(entries, fn {path, content, mode} ->
        stat =
          %File.Stat{
            size: byte_size(content),
            type: :regular,
            access: :read_write,
            atime: {{2020, 1, 1}, {0, 0, 0}},
            mtime: {{2020, 1, 1}, {0, 0, 0}},
            ctime: {{2020, 1, 1}, {0, 0, 0}},
            mode: mode,
            links: 1,
            major_device: 0,
            minor_device: 0,
            inode: 0,
            uid: 0,
            gid: 0
          }
          |> File.Stat.to_record()

        {String.to_charlist(path), content, stat}
      end)

    {:ok, {_name, binary}} = :zip.create(~c"hostile.zip", entries, [:memory])
    binary
  end

  defp replace_zip_entry(binary, target, replacement) do
    {:ok, entries} = :zip.extract(binary, [:memory])

    entries =
      Enum.map(entries, fn {path, content} ->
        value = if to_string(path) == target, do: replacement, else: content
        {to_string(path), IO.iodata_to_binary(value), 0o644}
      end)

    raw_zip(entries)
  end

  defp repackage(kind, archive, files, manifest \\ nil) do
    manifest =
      (manifest || archive.manifest)
      |> Map.drop(["format", "files", "content_hash"])

    PortableArchive.create(kind, files, manifest, "repackaged")
  end
end
