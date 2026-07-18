defmodule HydraAgentWeb.BlueprintControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.Simulations.{BlueprintManifest, Blueprints, BlueprintVersion}

  setup do
    workspace = workspace_fixture(%{name: "Simulation Lab", slug: "blueprint-controller"})
    built_ins = Blueprints.ensure_builtins!()
    %{workspace: workspace, built_ins: built_ins}
  end

  test "the library is minimal, bilingual, and exposes exactly two built-ins", %{
    conn: conn,
    workspace: workspace
  } do
    english =
      conn
      |> get("/blueprints?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert english =~ "How Hydra builds a simulation"
    assert english =~ "General Agent Simulation"
    assert english =~ "Decision Replay"
    assert english =~ "Four instruction modules"
    assert english =~ "Only declarative .hydra-blueprint packages are accepted"
    assert english =~ "Simulations"
    assert english =~ "Blueprints"
    assert english =~ "Settings"
    assert english =~ "Operations"
    refute english =~ "style="

    russian =
      conn
      |> recycle()
      |> get("/blueprints?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "<html lang=\"ru\""
    assert russian =~ "Как Hydra строит симуляцию"
    assert russian =~ "Универсальная агентная симуляция"
    assert russian =~ "Реконструкция решения"
    assert russian =~ "Четыре модуля инструкций"
  end

  test "a built-in can be duplicated, opened, and edited through four instruction cards", %{
    conn: conn,
    workspace: workspace,
    built_ins: [general | _]
  } do
    duplicated =
      post(conn, "/blueprints/#{general.id}/duplicate", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert redirected_to(duplicated) =~ "/blueprints/"
    [copy] = Enum.reject(Blueprints.list_blueprints(workspace.id), & &1.built_in)

    detail =
      conn
      |> recycle()
      |> get("/blueprints/#{copy.id}?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert detail =~ "General Agent Simulation copy"
    assert detail =~ "Immutable version history"
    assert detail =~ "Export package"

    editor =
      conn
      |> recycle()
      |> get("/blueprints/#{copy.id}/edit?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert editor =~ "Refine the method"
    assert length(Regex.scan(~r/name="blueprint\[instructions\]\[[^"]+\]"/, editor)) == 4
    assert editor =~ "Restore built-in default"
    assert editor =~ "Raw manifest YAML"
    assert editor =~ "Saving creates a new immutable version"
  end

  test "saving creates a higher immutable version and invalid edits save nothing", %{
    conn: conn,
    workspace: workspace,
    built_ins: [general | _]
  } do
    {:ok, copy} = Blueprints.duplicate_blueprint(general, workspace, nil)
    version = copy.active_version
    initial_count = Repo.aggregate(BlueprintVersion, :count)

    invalid =
      patch(conn, "/blueprints/#{copy.id}", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "blueprint" => %{
          "version" => "1.0.0",
          "manifest_yaml" => BlueprintManifest.encode(version.manifest),
          "instructions" => version.instructions
        }
      })

    assert html_response(invalid, 422) =~ "Nothing was saved"
    assert Repo.aggregate(BlueprintVersion, :count) == initial_count

    manifest = version.manifest |> Map.put("version", "1.1.0") |> BlueprintManifest.encode()

    instructions =
      Map.update!(version.instructions, "report", &(&1 <> "\nKeep conclusions concise."))

    saved =
      conn
      |> recycle()
      |> patch("/blueprints/#{copy.id}", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "blueprint" => %{
          "version" => "1.1.0",
          "manifest_yaml" => manifest,
          "instructions" => instructions
        }
      })

    assert redirected_to(saved) =~ "/blueprints/#{copy.id}"

    assert Blueprints.get_blueprint_for_workspace!(workspace.id, copy.id).active_version.version ==
             "1.1.0"

    assert Repo.aggregate(BlueprintVersion, :count) == initial_count + 1
  end

  test "Blueprint Test reports its bounded outcome without publishing", %{
    conn: conn,
    workspace: workspace,
    built_ins: [general | _]
  } do
    count = Repo.aggregate(BlueprintVersion, :count)

    html =
      conn
      |> post("/blueprints/#{general.id}/test", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })
      |> html_response(200)

    assert html =~ "Blueprint Test"
    assert html =~ "Passed"
    assert html =~ "3 agents · 2 rounds"
    assert html =~ "0</strong><span>provider calls"
    assert html =~ "Tested only · no version published"
    assert Repo.aggregate(BlueprintVersion, :count) == count
  end

  test "export is a downloadable portable archive", %{
    conn: conn,
    workspace: workspace,
    built_ins: [general | _]
  } do
    response =
      get(
        conn,
        "/blueprints/#{general.id}/export?workspace_id=#{workspace.id}&locale=en"
      )

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/zip"]
    assert get_resp_header(response, "content-disposition") |> hd() =~ ".hydra-blueprint"
    assert {:ok, _package} = HydraAgent.Simulations.BlueprintPackage.import(response.resp_body)
  end

  test "a malicious import is rejected without creating a record", %{
    conn: conn,
    workspace: workspace
  } do
    path =
      Path.join(
        System.tmp_dir!(),
        "malicious-#{System.unique_integer([:positive])}.hydra-blueprint"
      )

    {:ok, {_name, archive}} =
      :zip.create(~c"malicious.zip", [{~c"blueprint/../escape.txt", "escape"}], [:memory])

    File.write!(path, archive)
    on_exit(fn -> File.rm(path) end)
    before_count = length(Blueprints.list_blueprints(workspace.id))

    response =
      post(conn, "/blueprints/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "package" => %Plug.Upload{
          path: path,
          filename: "malicious.hydra-blueprint",
          content_type: "application/zip"
        }
      })

    assert redirected_to(response) == "/blueprints?locale=en&workspace_id=#{workspace.id}"
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "package was rejected"
    assert length(Blueprints.list_blueprints(workspace.id)) == before_count
  end

  test "the import feature flag removes the surface and rejects direct posts", %{
    conn: conn,
    workspace: workspace
  } do
    original = Application.get_env(:hydra_agent, :product_features, [])

    disabled =
      original
      |> Map.new()
      |> Map.put(:blueprint_import, false)

    Application.put_env(:hydra_agent, :product_features, disabled)
    on_exit(fn -> Application.put_env(:hydra_agent, :product_features, original) end)

    html =
      conn
      |> get("/blueprints?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    refute html =~ "Import a Blueprint"

    response =
      conn
      |> recycle()
      |> post("/blueprints/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert redirected_to(response) == "/blueprints?locale=en&workspace_id=#{workspace.id}"
    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "import is unavailable"
  end

  test "viewer sessions can inspect but cannot change Blueprints or see Operations", %{
    conn: conn,
    workspace: workspace,
    built_ins: [general | _]
  } do
    original = Application.get_env(:hydra_agent, :browser_auth)
    Application.put_env(:hydra_agent, :browser_auth, enabled?: true)

    on_exit(fn -> Application.put_env(:hydra_agent, :browser_auth, original) end)

    viewer = user_fixture()
    membership_fixture(viewer, workspace, "viewer")

    conn =
      init_test_session(conn,
        user_id: viewer.id,
        session_version: viewer.session_version
      )

    html =
      conn
      |> get("/blueprints?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert html =~ "General Agent Simulation"
    refute html =~ ">Operations<"
    refute html =~ ">Duplicate<"
    refute html =~ "Import a Blueprint"

    denied =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> post("/blueprints/#{general.id}/duplicate", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert denied.status == 404
  end
end
