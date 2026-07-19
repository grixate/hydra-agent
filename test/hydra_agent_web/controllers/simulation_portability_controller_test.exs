defmodule HydraAgentWeb.SimulationPortabilityControllerTest do
  use HydraAgentWeb.ConnCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Repo, Simulations}

  alias HydraAgent.Simulations.{
    Blueprints,
    ContextPack,
    Engine,
    PopulationModel,
    PortableArchive,
    Simulation
  }

  setup do
    workspace = workspace_fixture(%{name: "Portable UI", slug: "portable-interface"})
    [general, _decision] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general}
  end

  test "index and Build present a quiet bilingual portability workflow", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    simulation = simulation_fixture(workspace, general)

    index =
      conn
      |> get("/simulations?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert index =~ "Import Simulation Pack"
    assert index =~ "Hydra checks archive safety"
    refute index =~ "style="

    build =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/build?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert build =~ "Move or reproduce this simulation"
    assert build =~ "Download Simulation Pack"
    assert build =~ "Raw sources and provider details are excluded by default"
    assert build =~ "Use an external model manually"
    assert build =~ "Download external-model request"
    assert build =~ "without provider credentials"
    refute build =~ "style="

    russian =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/build?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "Перенос и воспроизведение симуляции"
    assert russian =~ "Скачать пакет симуляции"
    assert russian =~ "Ручная работа с внешней моделью"
  end

  test "safe Simulation Pack downloads and validated uploads keep predictable headers and state",
       %{
         conn: conn,
         workspace: workspace,
         general: general
       } do
    simulation = simulation_fixture(workspace, general)

    export_conn =
      get(
        conn,
        "/simulations/#{simulation.id}/export/simpack?workspace_id=#{workspace.id}&locale=en"
      )

    binary = response(export_conn, 200)
    assert get_resp_header(export_conn, "content-type") == ["application/vnd.hydra.simpack+zip"]
    assert get_resp_header(export_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(export_conn, "x-content-type-options") == ["nosniff"]
    assert hd(get_resp_header(export_conn, "content-disposition")) =~ ".hydra-simpack"

    assert {:ok, archive} = PortableArchive.import(:simpack, binary)
    refute Map.has_key?(archive.files, "raw-sources.json")
    assert archive.manifest["privacy"]["provider_details"] == "omitted"

    path = temporary_file("portable-ui", binary)
    on_exit(fn -> File.rm(path) end)

    response =
      conn
      |> recycle()
      |> post("/simulations/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation_pack" => %{
          "file" => %Plug.Upload{
            path: path,
            filename: "validated.hydra-simpack",
            content_type: "application/zip"
          }
        }
      })

    assert response.status == 302
    assert redirected_to(response) =~ ~r{/simulations/\d+/build\?locale=en&workspace_id=}
    assert Phoenix.Flash.get(response.assigns.flash, :info) =~ "Simulation imported"
    assert Repo.aggregate(Simulation, :count) == 2
  end

  test "manual artifacts and Run Packs are exposed through bounded, inspectable workflows", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    simulation = simulation_fixture(workspace, general, %{"population_size" => "36"})

    request_conn =
      get(
        conn,
        "/simulations/#{simulation.id}/manual-request.json?workspace_id=#{workspace.id}&locale=en"
      )

    request = request_conn |> response(200) |> Jason.decode!()
    assert request["privacy"]["raw_sources"] == "excluded"
    assert get_resp_header(request_conn, "cache-control") == ["private, no-store"]

    bundle = manual_bundle(simulation, request)
    manual_path = temporary_file("manual-artifacts", Jason.encode!(bundle))
    on_exit(fn -> File.rm(manual_path) end)

    imported =
      conn
      |> recycle()
      |> post("/simulations/#{simulation.id}/manual-import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "manual_artifacts" => %{
          "file" => %Plug.Upload{
            path: manual_path,
            filename: "completed-artifacts.json",
            content_type: "application/json"
          }
        }
      })

    assert redirected_to(imported) ==
             "/simulations/#{simulation.id}/build?locale=en&workspace_id=#{workspace.id}"

    assert Phoenix.Flash.get(imported.assigns.flash, :info) =~ "New immutable build versions"

    simulation = Simulations.get_simulation_for_workspace!(workspace.id, simulation.id)
    assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
    assert {:ok, _record} = Engine.execute(record.id)
    record = Simulations.get_simulation_run_record!(record.id)

    results =
      conn
      |> recycle()
      |> get(
        "/simulations/#{simulation.id}/results?workspace_id=#{workspace.id}&locale=en&run_id=#{record.id}"
      )
      |> html_response(200)

    assert results =~ "Run Pack"
    assert results =~ "Reproducible audit record"
    assert results =~ "model rationales"

    run_conn =
      conn
      |> recycle()
      |> get(
        "/simulations/#{simulation.id}/results/runs/#{record.id}/export/run-pack?workspace_id=#{workspace.id}&locale=en"
      )

    run_binary = response(run_conn, 200)
    assert get_resp_header(run_conn, "content-type") == ["application/vnd.hydra.run+zip"]
    assert hd(get_resp_header(run_conn, "content-disposition")) =~ ".hydra-run"
    assert {:ok, inspected} = Simulations.inspect_run_pack(run_binary)
    assert inspected.run["result_hash"] == record.result_hash
    assert inspected.privacy["model_rationales"] == "omitted"
    assert inspected.privacy["provider_details"] == "omitted"
  end

  test "portable uploads reject files outside Plug's temporary boundary", %{
    conn: conn,
    workspace: workspace
  } do
    path =
      Path.join(
        File.cwd!(),
        "portable-outside-upload-root-#{System.unique_integer([:positive])}.hydra-simpack"
      )

    File.write!(path, "not-an-archive")
    on_exit(fn -> File.rm(path) end)

    response =
      post(conn, "/simulations/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation_pack" => %{
          "file" => %Plug.Upload{
            path: path,
            filename: "outside.hydra-simpack",
            content_type: "application/zip"
          }
        }
      })

    assert redirected_to(response) ==
             "/simulations?locale=en&workspace_id=#{workspace.id}"

    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Choose a valid"
    assert Repo.aggregate(Simulation, :count) == 0
  end

  defp simulation_fixture(workspace, blueprint, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "title" => "Portable interface model",
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

  defp temporary_file(prefix, content) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end
end
