defmodule HydraAgentWeb.SimulationControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.Schemas.Study
  alias HydraAgent.Simulations.{Blueprints, Simulation, SimulationScript, SimulationVersion}

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

  test "a question-only submission creates durable context and deep-links directly to Build", %{
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
    assert build =~ "Context is usable with gaps"
    assert build =~ "Context Pack v1"
    assert build =~ "2 claims"
    assert build =~ "3 assumptions"
    refute build =~ "3 assumptionss"
    assert build =~ "Context and assumptions"
    assert build =~ "Inspect context"
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
          "historical_cutoff" => "2024-01-31",
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
    [simulation] = Repo.all(Simulation) |> Repo.preload([:active_version, :active_context_pack])
    version = simulation.active_version
    assert version.population_size == 8_000
    assert version.normalized_input["geography"] == "Germany"
    assert version.normalized_input["horizon"] == "one quarter"
    assert version.normalized_input["historical_cutoff"] == "2024-01-31"
    assert simulation.active_context_pack.historical_cutoff == ~D[2024-01-31]
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

    invalid_cutoff =
      conn
      |> recycle()
      |> post("/simulations?workspace_id=#{workspace.id}&locale=en", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "simulation" => %{
          "question" => "How might a historical replay enforce its date boundary?",
          "blueprint_id" => to_string(general.id),
          "locale" => "en",
          "execution_mode" => "quick",
          "historical_cutoff" => "not-a-date"
        }
      })

    assert html_response(invalid_cutoff, 422) =~ "valid historical cutoff date"
    assert Repo.aggregate(Simulation, :count) == 0
  end

  test "the Context inspector is traceable, bilingual, and source exclusion versions the Pack", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a staffing policy alter service queues?",
        "blueprint_id" => general.id,
        "geography" => "Germany",
        "horizon" => "one quarter",
        "historical_cutoff" => "2024-01-31",
        "inputs" => %{"notes" => "Peak demand is twice the daily average."}
      })

    [source] = Enum.filter(simulation.active_context_pack.sources, &(&1["kind"] == "user_data"))

    english_path =
      "/simulations/#{simulation.id}/context?workspace_id=#{workspace.id}&locale=en"

    english = conn |> get(english_path) |> html_response(200)

    assert english =~ "<h1>Context and assumptions</h1>"
    assert english =~ "Interpreted world"
    assert english =~ "Peak demand is twice the daily average."
    assert english =~ "User data"
    assert english =~ "Model prior"
    assert english =~ "Assumptions"
    assert english =~ "2024-01-31"
    assert english =~ "Pack version"
    assert english =~ "v1"
    assert english =~ "1 assumption"
    refute english =~ "1 assumptions"
    assert english =~ "Informal influencer"
    refute english =~ "informal_influencer"
    assert english =~ "Research not run"
    assert english =~ "Exclude source"
    refute english =~ "Oban"
    refute english =~ "worker"

    russian =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/context?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "<html lang=\"ru\""
    assert russian =~ "<h1>Контекст и допущения</h1>"
    assert russian =~ "Интерпретация мира"
    assert russian =~ "Историческая отсечка"

    response =
      conn
      |> recycle()
      |> post("/simulations/#{simulation.id}/context/sources/#{source["id"]}/exclude", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert redirected_to(response) ==
             "/simulations/#{simulation.id}/context?locale=en&workspace_id=#{workspace.id}"

    refreshed = HydraAgent.Simulations.get_simulation_for_workspace!(workspace.id, simulation.id)
    assert refreshed.active_context_pack.version == 2
    refute Enum.any?(refreshed.active_context_pack.sources, &(&1["id"] == source["id"]))
  end

  test "the Population inspector is quiet, traceable, bilingual, and honest about prose", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a service change move through a participant network?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    path = "/simulations/#{simulation.id}/population?workspace_id=#{workspace.id}&locale=en"
    english = conn |> get(path) |> html_response(200)

    assert english =~ "<h1>Population model</h1>"
    assert english =~ "Population structure is ready"
    assert english =~ "50"
    assert english =~ "Agent types"
    assert english =~ "Archetypes"
    assert english =~ "Relationship topology"
    assert english =~ "Representatives"
    assert english =~ "Structured state"
    assert english =~ "No protected or sensitive traits were inferred"
    assert english =~ "Relationship CSV mapping"
    assert english =~ "Readable cards are optional projections"
    refute english =~ "style="
    refute english =~ "synthetic biography"

    russian =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/population?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "<html lang=\"ru\""
    assert russian =~ "<h1>Модель популяции</h1>"
    assert russian =~ "Структурированное состояние"

    [representative | _] = simulation.active_population_model.compile_summary["representatives"]

    response =
      conn
      |> recycle()
      |> post(
        "/simulations/#{simulation.id}/population/personas/#{representative["agent_id"]}",
        %{
          "workspace_id" => to_string(workspace.id),
          "locale" => "en"
        }
      )

    assert redirected_to(response) ==
             "/simulations/#{simulation.id}/population?locale=en&workspace_id=#{workspace.id}"

    projected =
      conn
      |> recycle()
      |> get(path)
      |> html_response(200)

    assert projected =~ "not a biography of a real person"
    assert projected =~ "Readable projection · not authoritative state"
  end

  test "Population CSV upload preserves valid rows and shows row-level errors", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might supplied participant rows affect a bounded population?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    type_id = hd(simulation.active_population_model.agent_types)["id"]

    upload_path =
      Path.join(System.tmp_dir!(), "population-#{System.unique_integer([:positive])}.csv")

    File.write!(
      upload_path,
      "id,type,attribute_imported_signal\nagent-1,#{type_id},0.8\ninvalid id,#{type_id},secret-value\n"
    )

    on_exit(fn -> File.rm(upload_path) end)

    response =
      post(conn, "/simulations/#{simulation.id}/population/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "population_import" => %{
          "kind" => "agents",
          "file" => %Plug.Upload{
            path: upload_path,
            filename: "population.csv",
            content_type: "text/csv"
          }
        }
      })

    assert redirected_to(response) ==
             "/simulations/#{simulation.id}/population?locale=en&workspace_id=#{workspace.id}"

    html =
      conn
      |> recycle()
      |> get(redirected_to(response))
      |> html_response(200)

    assert html =~ "Latest import"
    assert html =~ "Rows needing attention"
    assert html =~ "A required identifier is missing or invalid."
    refute html =~ "secret-value"
  end

  test "Population import rejects upload paths outside Plug's temporary boundary", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How should untrusted population upload paths be handled?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    upload_path =
      Path.join(
        File.cwd!(),
        "population-outside-upload-root-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(upload_path, "id,type\nagent-1,participant\n")
    on_exit(fn -> File.rm(upload_path) end)

    response =
      post(conn, "/simulations/#{simulation.id}/population/import", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en",
        "population_import" => %{
          "kind" => "agents",
          "file" => %Plug.Upload{
            path: upload_path,
            filename: "population.csv",
            content_type: "text/csv"
          }
        }
      })

    assert redirected_to(response) ==
             "/simulations/#{simulation.id}/population?locale=en&workspace_id=#{workspace.id}"

    assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "Nothing was imported"
  end

  test "the Script inspector explains the exact validated contract in English and Russian", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might teams respond to a staged operating model change?",
        "blueprint_id" => general.id,
        "horizon" => "8 weeks",
        "population_size" => 50
      })

    path = "/simulations/#{simulation.id}/script?workspace_id=#{workspace.id}&locale=en"
    english = conn |> get(path) |> html_response(200)

    assert english =~ "<h1>Simulation Script</h1>"
    assert english =~ "Preview passed"
    assert english =~ "8"
    assert english =~ "Typed operations only"
    assert english =~ "No external side effects"
    assert english =~ "Available choices"
    assert english =~ "Decision policies"
    assert english =~ "Recorded outputs"
    assert english =~ "Download YAML"
    assert english =~ "Download JSON"
    assert english =~ "Technical lineage"
    refute english =~ "style="
    refute english =~ "Elixir"

    russian =
      conn
      |> recycle()
      |> get("/simulations/#{simulation.id}/script?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert russian =~ "<html lang=\"ru\""
    assert russian =~ "<h1>Сценарий симуляции</h1>"
    assert russian =~ "Мини-прогон пройден"
    assert russian =~ "Только типизированные операции"
    assert russian =~ "Политики решений"
    assert russian =~ "раундов"
    assert russian =~ "Политика: участник"
    assert russian =~ "Принять · количество"
    refute russian =~ "participant_response_policy"
    refute russian =~ ">points<"
    refute russian =~ ">hours<"

    count = Repo.aggregate(SimulationScript, :count)

    rebuilt =
      conn
      |> recycle()
      |> post("/simulations/#{simulation.id}/script/build", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert redirected_to(rebuilt) ==
             "/simulations/#{simulation.id}/script?locale=en&workspace_id=#{workspace.id}"

    assert Repo.aggregate(SimulationScript, :count) == count
  end

  test "Script exports are deterministic, complete, and correctly typed", %{
    conn: conn,
    workspace: workspace,
    general: general
  } do
    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a bounded service policy affect participant choices?",
        "blueprint_id" => general.id,
        "population_size" => 50
      })

    base = "/simulations/#{simulation.id}/script/export"
    query = "?workspace_id=#{workspace.id}&locale=en"

    json = conn |> get(base <> "/json" <> query) |> response(200)
    decoded = Jason.decode!(json)
    assert decoded["hydra_simulation_script"] == 1
    assert is_list(decoded["actions"])
    assert is_list(decoded["stopping_conditions"])

    json_conn = conn |> recycle() |> get(base <> "/json" <> query)
    assert get_resp_header(json_conn, "content-type") == ["application/json"]
    assert hd(get_resp_header(json_conn, "content-disposition")) =~ "simulation-script-v1.json"

    yaml_conn = conn |> recycle() |> get(base <> "/yaml" <> query)
    yaml = response(yaml_conn, 200)
    assert get_resp_header(yaml_conn, "content-type") == ["application/yaml"]
    assert hd(get_resp_header(yaml_conn, "content-disposition")) =~ "simulation-script-v1.yaml"
    assert yaml =~ "hydra_simulation_script: 1"
    assert yaml =~ "stopping_conditions:"
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

    context =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> get("/simulations/#{simulation.id}/context?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert context =~ "Context and assumptions"
    refute context =~ "Exclude source"
    refute context =~ "Add bounded web context"

    population =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> get("/simulations/#{simulation.id}/population?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert population =~ "Population model"
    refute population =~ "Validate and import"
    refute population =~ ">Remove<"
    refute population =~ "Create readable card"

    script =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> get("/simulations/#{simulation.id}/script?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert script =~ "Simulation Script"
    assert script =~ "Download YAML"
    refute script =~ "Rebuild from current population"

    export =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> get(
        "/simulations/#{simulation.id}/script/export/json?workspace_id=#{workspace.id}&locale=en"
      )

    assert export.status == 200

    denied_script_build =
      conn
      |> recycle()
      |> init_test_session(user_id: viewer.id, session_version: viewer.session_version)
      |> post("/simulations/#{simulation.id}/script/build", %{
        "workspace_id" => to_string(workspace.id),
        "locale" => "en"
      })

    assert denied_script_build.status == 404

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
