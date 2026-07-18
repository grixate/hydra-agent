defmodule HydraAgentWeb.SimulationControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.Schemas.Study
  alias HydraAgent.Simulations.{Blueprints, Simulation, SimulationVersion}

  setup do
    workspace = workspace_fixture(%{name: "Simulation Studio", slug: "simulation-controller"})
    [general, decision_replay] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general, decision_replay: decision_replay}
  end

  test "the index is quiet, bilingual, and starts with one clear action", %{
    conn: conn,
    workspace: workspace
  } do
    english =
      conn
      |> get("/simulations?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert english =~ "<h1>Simulations</h1>"
    assert english =~ "New simulation"
    assert english =~ "Start with one question"
    assert english =~ "Simulations"
    assert english =~ "Blueprints"
    assert english =~ "Settings"
    refute english =~ "style="
    refute english =~ "Total simulations"

    russian =
      conn
      |> recycle()
      |> get("/simulations?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "<html lang=\"ru\""
    assert russian =~ "<h1>Симуляции</h1>"
    assert russian =~ "Новая симуляция"
    assert russian =~ "Начните с одного вопроса"
  end

  test "a question-only submission creates a durable draft and deep-links directly to Build", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    response =
      post(conn, "/simulations?workspace_id=#{workspace.id}&locale=en", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation" => %{
          "question" => "How might employees respond to a four-day workweek?",
          "blueprint_id" => to_string(general.id),
          "locale" => "en",
          "execution_mode" => "quick",
          "population_size" => "5000"
        }
      })

    [simulation] = Repo.all(Simulation)

    assert redirected_to(response) ==
             "/simulations/#{simulation.id}/build?locale=en&workspace_id=#{workspace.id}"

    build =
      conn
      |> recycle()
      |> get(redirected_to(response))
      |> html_response(200)

    assert build =~ "Build the world"
    assert build =~ "Build not started"
    assert build =~ "No provider has been called"
    assert build =~ "Understanding the question"
    assert build =~ "Finding useful context"
    assert build =~ "Designing the population"
    assert build =~ "Writing the simulation rules"
    assert build =~ "Checking the model"
    assert build =~ "Preparing the run"
    assert build =~ "Four narrow responsibilities"
    assert build =~ "No optional evidence attached"
    refute build =~ "Oban"
    refute build =~ "worker"

    refreshed =
      conn
      |> recycle()
      |> get(redirected_to(response))
      |> html_response(200)

    assert refreshed =~ simulation.title
    assert Repo.aggregate(SimulationVersion, :count) == 1
  end

  test "the composer persists bounded files, URLs, notes, geography, and horizon", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    path =
      Path.join(System.tmp_dir!(), "simulation-input-#{System.unique_integer([:positive])}.json")

    File.write!(path, ~s({"segments":[{"name":"early adopters","share":0.2}]}))
    on_exit(fn -> File.rm(path) end)

    response =
      post(conn, "/simulations?workspace_id=#{workspace.id}&locale=en", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation" => %{
          "question" => "How could a loyalty program change customer behavior?",
          "blueprint_id" => to_string(general.id),
          "locale" => "en",
          "execution_mode" => "quick",
          "population_size" => "8000",
          "geography" => "Germany",
          "horizon" => "one quarter",
          "notes" => "Inventory is capped at current capacity.",
          "urls" => "https://example.com/research#summary\nhttps://openai.com/research",
          "files" => [
            %Plug.Upload{
              path: path,
              filename: "segments.json",
              content_type: "application/json"
            }
          ]
        }
      })

    assert response.status == 302
    [simulation] = Repo.all(Simulation) |> Repo.preload(:active_version)
    version = simulation.active_version
    assert version.population_size == 8_000
    assert version.normalized_input["geography"] == "Germany"
    assert version.normalized_input["horizon"] == "one quarter"
    assert version.inputs["notes"] == "Inventory is capped at current capacity."

    assert Enum.map(version.inputs["urls"], & &1["uri"]) == [
             "https://example.com/research",
             "https://openai.com/research"
           ]

    assert [%{"filename" => "segments.json", "text" => text}] = version.inputs["files"]
    assert Jason.decode!(text)["segments"] |> hd() |> Map.fetch!("name") == "early adopters"
    refute Jason.encode!(version.inputs) =~ path
  end

  test "unsafe optional input and disabled modes save nothing", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    invalid_url =
      post(conn, "/simulations?workspace_id=#{workspace.id}&locale=en", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation" => %{
          "question" => "How might invalid source input affect a simulation?",
          "blueprint_id" => to_string(general.id),
          "locale" => "en",
          "execution_mode" => "quick",
          "urls" => "http://127.0.0.1/private"
        }
      })

    assert html_response(invalid_url, 422) =~ "Use public HTTPS URLs"
    assert Repo.aggregate(Simulation, :count) == 0

    disabled_mode =
      conn
      |> recycle()
      |> post("/simulations?workspace_id=#{workspace.id}&locale=en", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation" => %{
          "question" => "How might a disabled execution mode be rejected?",
          "blueprint_id" => to_string(general.id),
          "locale" => "en",
          "execution_mode" => "deep"
        }
      })

    assert html_response(disabled_mode, 422) =~ "not enabled"
    assert Repo.aggregate(Simulation, :count) == 0
  end

  test "Run, Results, and Compare are honest deep-linkable gates", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a pricing change affect customer retention?",
        "blueprint_id" => general.id,
        "execution_mode" => "quick"
      })

    run =
      conn
      |> get("/simulations/#{simulation.id}/run?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert run =~ "Not ready to run"
    assert run =~ "incomplete or unvalidated Simulation Pack"
    assert run =~ "5000"
    assert run =~ "Quick"
    assert run =~ ~s(button type="button" disabled)

    results =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/results?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert results =~ "Results will appear after a completed run"
    assert results =~ "Locked · State"
    assert results =~ "Locked · Flow"
    assert results =~ "Locked · Explain"

    compare =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/compare?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert compare =~ "Run at least two compatible scenarios"
  end

  test "duplicate and archive remain workspace-scoped and preserve history", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a queue design change service waiting time?",
        "blueprint_id" => general.id
      })

    duplicate =
      post(conn, "/simulations/#{simulation.id}/duplicate", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert duplicate.status == 302
    assert Repo.aggregate(Simulation, :count) == 2
    assert Repo.aggregate(SimulationVersion, :count) == 2

    archive =
      conn
      |> recycle()
      |> post("/simulations/#{simulation.id}/archive", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert redirected_to(archive) == "/simulations?locale=en&workspace_id=#{workspace.id}"
    assert Repo.get!(Simulation, simulation.id).status == "archived"
    assert Repo.aggregate(SimulationVersion, :count) == 2
  end

  test "legacy studies remain discoverable without conversion", %{
    conn: conn,
    workspace: workspace
  } do
    study =
      %Study{}
      |> Study.changeset(%{
        workspace_id: workspace.id,
        title: "Existing decision record",
        question: "What did the team know before launch?",
        status: "draft"
      })
      |> Repo.insert!()

    html =
      conn
      |> get("/simulations?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert html =~ "Previous SimLab study"
    assert html =~ study.title
    assert html =~ "/lab/workspaces/#{workspace.id}/studies/#{study.id}"
  end

  test "viewers can inspect but cannot create, duplicate, archive, or see Operations", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a viewer inspect a saved simulation safely?",
        "blueprint_id" => general.id
      })

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
      |> get("/simulations?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert html =~ simulation.title
    refute html =~ ">Operations<"
    refute html =~ ">New simulation<"
    refute html =~ ">Duplicate<"
    refute html =~ ">Archive<"

    denied =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> post("/simulations/#{simulation.id}/duplicate", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert denied.status == 404
  end
end
