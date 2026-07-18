defmodule HydraAgentWeb.SimLabWorkspaceControllerTest do
  use HydraAgentWeb.ConnCase, async: true
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.SimLab
  alias HydraAgent.SimLab.Simulations

  test "starting-model action reports the complete editable directional draft", %{conn: conn} do
    workspace = workspace_fixture()

    {:ok, study} =
      SimLab.create_study(%{
        workspace_id: workspace.id,
        title: "Checkout adoption",
        question: "Will shoppers adopt a faster retail checkout?",
        domain: "retail checkout",
        target_audience: "shoppers"
      })

    path = "/lab/workspaces/#{workspace.id}/studies/#{study.id}"
    draft_conn = post(conn, path <> "/behavior-draft")

    assert redirected_to(draft_conn) == path

    assert Phoenix.Flash.get(draft_conn.assigns.flash, :info) =~
             "Generated 5 editable segments and 20 directional action rules."

    html = draft_conn |> recycle() |> get(path) |> html_response(200)

    assert html =~ "Outcome-led evaluators"
    assert html =~ "shoppers in retail checkout"
    assert html =~ "Practical value becomes legible"
    assert length(HydraAgent.SimLab.Studies.list_personas(study)) == 5
    assert length(HydraAgent.SimLab.Studies.list_action_patterns(study)) == 20

    repeated = post(conn, path <> "/behavior-draft")
    assert redirected_to(repeated) == path
    assert length(HydraAgent.SimLab.Studies.list_personas(study)) == 5
    assert length(HydraAgent.SimLab.Studies.list_action_patterns(study)) == 20
  end

  test "a workspace can create and reopen a durable study", %{conn: conn} do
    workspace = workspace_fixture()

    html =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies")
      |> html_response(200)

    assert html =~ "Frame the decision."
    assert html =~ "Saved studies."

    create_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies", %{
        "study" => %{
          "question" => "How will new managers react to a visible learning portfolio?",
          "target_audience" => "new managers",
          "domain" => "workforce learning",
          "region" => "Germany",
          "timeframe" => "90 days"
        }
      })

    assert redirected_to(create_conn) =~ "/lab/workspaces/#{workspace.id}/studies/"
    [study] = SimLab.list_studies(workspace.id)

    dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert dossier =~ "How will new managers react"
    assert dossier =~ "No evidence pack yet."
    assert dossier =~ "Inspectable by design."
    assert dossier =~ "Advanced web search"
    assert dossier =~ "Tavily-ready retrieval"
    assert dossier =~ "Local Codex test"
    assert dossier =~ "Never presented as sourced research"
    assert dossier =~ "Preview outbound queries"
    assert dossier =~ "Only these queries leave Hydra"
    assert dossier =~ "private study detail"

    note_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/notes", %{
        "note" => %{"note" => "Managers already discuss portfolios in promotion cycles."}
      })

    assert redirected_to(note_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    updated_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert updated_dossier =~ "Evidence, kept legible."
    assert updated_dossier =~ "Managers already discuss portfolios"
    assert updated_dossier =~ "Refresh from stored evidence"
    assert updated_dossier =~ "Use in model"

    [first_evidence | _] = HydraAgent.SimLab.Studies.list_evidence(study)

    review_conn =
      post(
        conn,
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/evidence/#{first_evidence.id}/review",
        %{"decision" => "reviewed"}
      )

    assert redirected_to(review_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    assert HydraAgent.Repo.reload!(first_evidence).metadata["review_status"] == "reviewed"

    refresh_context_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/context/refresh")

    assert redirected_to(refresh_context_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    refreshed_context = HydraAgent.SimLab.Studies.active_context_pack(study)
    assert refreshed_context.summary["research_status"] == "workspace_evidence_synthesis"

    second_note_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/notes", %{
        "note" => %{
          "title" => "Pilot interview",
          "note" => "Managers want clear visibility controls before sharing portfolios."
        }
      })

    assert redirected_to(second_note_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    enriched_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert enriched_dossier =~ "Add local evidence"
    assert enriched_dossier =~ "Managers want clear visibility controls"

    upload_path =
      Path.join(System.tmp_dir!(), "hydra-sim-pilot-#{System.unique_integer([:positive])}.md")

    File.write!(
      upload_path,
      "# Pilot findings\n\nManagers want a preview before portfolio visibility."
    )

    on_exit(fn -> File.rm(upload_path) end)

    upload_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/uploads", %{
        "document" => %{
          "title" => "Pilot findings",
          "file" => %Plug.Upload{
            path: upload_path,
            filename: "pilot-findings.md",
            content_type: "text/markdown"
          }
        }
      })

    assert redirected_to(upload_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    uploaded_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert uploaded_dossier =~ "Add a local document"
    assert uploaded_dossier =~ "Add a public web source"
    assert uploaded_dossier =~ "Pilot findings"

    [uploaded_source | _sources] = HydraAgent.SimLab.Studies.list_sources(study)

    remove_upload_conn =
      post(
        conn,
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/sources/#{uploaded_source.id}/remove"
      )

    assert redirected_to(remove_upload_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    removed_upload_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    refute removed_upload_dossier =~ "# Pilot findings"

    persona_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/personas", %{
        "persona" => %{
          "name" => "Cautious adopters",
          "segment" => "Risk-conscious new managers",
          "distribution_weight" => "0.35",
          "confidence" => "0.55",
          "goals" => ["Avoid surprises"],
          "frictions" => ["Default visibility"]
        }
      })

    assert redirected_to(persona_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    persona_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert persona_dossier =~ "Cautious adopters"
    assert persona_dossier =~ "35% of population"

    [persona] = HydraAgent.SimLab.Studies.list_personas(study)
    [evidence | _rest] = HydraAgent.SimLab.Studies.list_evidence(study)

    persona_revision_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/personas/#{persona.id}", %{
        "persona" => %{
          "name" => "Cautious reviewers",
          "segment" => "Risk-conscious new managers",
          "distribution_weight" => "0.4",
          "confidence" => "0.6",
          "goals" => ["Avoid surprises"],
          "frictions" => ["Default visibility"],
          "triggers" => ["A manager asks about the portfolio"],
          "trust_factors" => ["Clear controls"],
          "decision_style" => "Deliberate",
          "likely_actions" => ["resist"],
          "editable_notes" => "Review after pilot.",
          "evidence_refs" => [to_string(evidence.id)]
        }
      })

    assert redirected_to(persona_revision_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    revised_persona_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert revised_persona_dossier =~ "Cautious reviewers"
    assert revised_persona_dossier =~ "Review this segment"
    assert revised_persona_dossier =~ "Evidence linked"

    [persona] = HydraAgent.SimLab.Studies.list_personas(study)

    pattern_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/patterns", %{
        "pattern" => %{
          "persona_id" => to_string(persona.id),
          "name" => "Control before sharing",
          "condition" => "Portfolio is visible by default",
          "motivation" => "Avoid unwanted exposure",
          "likely_action" => "resist",
          "base_probability" => "0.62",
          "confidence" => "0.55"
        }
      })

    assert redirected_to(pattern_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    pattern_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert pattern_dossier =~ "Control before sharing"
    assert pattern_dossier =~ "62% base likelihood"

    [pattern] = HydraAgent.SimLab.Studies.list_action_patterns(study)

    pattern_revision_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/patterns/#{pattern.id}", %{
        "pattern" => %{
          "persona_id" => to_string(persona.id),
          "name" => "Control before sharing · reviewed",
          "condition" => "Privacy controls are unclear",
          "interpretation" => "Visibility feels like surveillance",
          "motivation" => "Avoid unexpected exposure",
          "likely_action" => "resist",
          "base_probability" => "0.7",
          "confidence" => "0.6",
          "blocker" => ["No clear settings"],
          "amplifier" => ["Manager recognition"],
          "evidence_refs" => [to_string(evidence.id)]
        }
      })

    assert redirected_to(pattern_revision_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    revised_pattern_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert revised_pattern_dossier =~ "Control before sharing · reviewed"
    assert revised_pattern_dossier =~ "Review this rule"
    assert revised_pattern_dossier =~ "1 linked evidence"

    behavior_export =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}/behavior-model.md")
      |> response(200)

    assert behavior_export =~ "# Behavior model"
    assert behavior_export =~ "Cautious reviewers"
    assert behavior_export =~ "Control before sharing · reviewed"
    assert behavior_export =~ "Grounding mix"

    scenario_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios", %{
        "scenario" => %{
          "name" => "Visible by default",
          "description" => "The portfolio appears in manager profiles.",
          "forecast_horizon" => "60 days",
          "simulation_modifier" => "manager_recognition",
          "event_day" => ["1", "14", "30"],
          "event_title" => ["Announcement", "First use", "Manager prompt"],
          "event_impact" => ["Awareness grows", "Interpretation diverges", "Movement increases"],
          "success_metric" => ["Opt-in adoption"]
        }
      })

    assert redirected_to(scenario_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    [scenario] = HydraAgent.SimLab.Simulations.list_scenarios(study)
    assert scenario.metadata["simulation_modifier"] == "manager_recognition"

    run_conn =
      post(
        conn,
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios/#{scenario.id}/run",
        %{
          "mode" => "small"
        }
      )

    observatory_path = redirected_to(run_conn)
    assert observatory_path =~ "/lab/workspaces/#{workspace.id}/studies/#{study.id}/observatory/"

    [queued_run] = HydraAgent.SimLab.Simulations.list_pending_runs(study)

    assert_enqueued(
      worker: HydraAgent.SimLab.Workers.SimulationRunWorker,
      args: %{run_id: queued_run.id}
    )

    pending_observatory = conn |> get(observatory_path) |> html_response(200)
    assert pending_observatory =~ "Preparing the aggregate replay."
    assert pending_observatory =~ "Cancel replay"
    assert pending_observatory =~ "data-pending-run=\"true\""

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{run_id: queued_run.id})

    observatory = conn |> get(observatory_path) |> html_response(200)
    assert observatory =~ "simulation-field"
    assert observatory =~ "tabindex=\"0\""
    assert observatory =~ "Visible by default"
    assert observatory =~ "Selected cohort"
    assert observatory =~ "data-pattern-insights"
    assert observatory =~ "Inspect representative trace"
    assert observatory =~ "data-trace-url-base"
    assert observatory =~ "Pattern flow"
    assert observatory =~ "field-mode-hint"
    assert observatory =~ "zoom-lens"

    run = HydraAgent.SimLab.Simulations.latest_run(study)
    run_with_report = HydraAgent.SimLab.Simulations.get_run!(study, run.id)

    saved_pattern =
      Enum.find(run_with_report.input_snapshot["patterns"], fn saved ->
        saved["id"] == to_string(pattern.id)
      end)

    pattern_at_run_time_version = pattern.version + 1
    assert saved_pattern["version"] == pattern_at_run_time_version
    assert saved_pattern["grounding_level"] == "direct_user_data"
    assert saved_pattern["evidence_refs"] == [to_string(evidence.id)]
    refute Jason.encode!(run_with_report.input_snapshot) =~ evidence.claim

    representative_agent_id =
      run_with_report
      |> HydraAgent.SimLab.Simulations.replay_snapshots()
      |> List.first()
      |> then(&hd(&1.clusters["groups"]))
      |> Map.fetch!("representative_agent_id")

    trace_path =
      "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/agents/#{representative_agent_id}/trace"

    trace_before_revision = conn |> get(trace_path) |> json_response(200)

    [pattern_at_run_time] = HydraAgent.SimLab.Studies.list_action_patterns(study)
    assert pattern_at_run_time.version == pattern_at_run_time_version

    assert {:ok, %{pattern: post_run_revision}} =
             HydraAgent.SimLab.Studies.update_action_pattern(
               study,
               pattern_at_run_time.id,
               persona.id,
               %{
                 name: "Post-run replacement rule",
                 condition: "The current model has changed",
                 interpretation: "This must not rewrite an old replay",
                 motivation: "Test historical isolation",
                 likely_action: "resist",
                 base_probability: 0.7,
                 confidence: 0.6,
                 blockers: [%{"statement" => "Mutable current blocker"}],
                 amplifiers: [],
                 executable_rule: %{"origin" => "post_run_revision"},
                 evidence_refs: [to_string(evidence.id)]
               }
             )

    assert post_run_revision.version == pattern_at_run_time.version + 1

    historical_observatory = conn |> get(observatory_path) |> html_response(200)
    assert historical_observatory =~ "Control before sharing · reviewed"
    refute historical_observatory =~ "Post-run replacement rule"

    trace_after_revision = conn |> get(trace_path) |> json_response(200)

    assert trace_after_revision["data"]["activated_pattern"] ==
             trace_before_revision["data"]["activated_pattern"]

    assert trace_after_revision["data"]["evidence_refs"] == [to_string(evidence.id)]

    assert trace_after_revision["data"]["activated_pattern"]["name"] ==
             "Control before sharing · reviewed · manager-recognition hypothesis"

    assert Enum.any?(run_with_report.forecast_report.assumptions, fn assumption ->
             assumption["statement"] =~ "manager recognition"
           end)

    variant_conn = post(conn, "#{observatory_path}/control-first-variant")

    assert redirected_to(variant_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"
    [variant | _rest] = HydraAgent.SimLab.Simulations.list_scenarios(study)
    assert variant.metadata["created_as_counterfactual"]
    assert variant.metadata["simulation_modifier"] == "control_first_opt_in"

    refinement_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios/#{variant.id}", %{
        "scenario" => %{
          "name" => "Opt-in portfolio framing",
          "description" => "The portfolio is opt-in and framed as a career record.",
          "forecast_horizon" => "45 days",
          "event_day" => ["1", "14"],
          "event_title" => ["Opt-in announcement", "Career prompt"],
          "event_impact" => ["Control is explicit.", "Motivation increases."],
          "success_metric" => ["Opt-in adoption"]
        }
      })

    assert redirected_to(refinement_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    variant = HydraAgent.SimLab.Simulations.get_scenario!(study, variant.id)
    assert variant.name == "Opt-in portfolio framing"
    assert variant.events |> List.first() |> Map.fetch!("title") == "Opt-in announcement"

    variant_run_conn =
      post(
        conn,
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios/#{variant.id}/run",
        %{"mode" => "small"}
      )

    assert redirected_to(variant_run_conn) =~ "/observatory/"
    [queued_variant_run] = HydraAgent.SimLab.Simulations.list_pending_runs(study)

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{
               run_id: queued_variant_run.id
             })

    variant_run = HydraAgent.SimLab.Simulations.latest_run(study)

    run_comparison = HydraAgent.SimLab.Simulations.compare_runs(study, run.id, variant_run.id)
    assert run_comparison.deltas["resist"] < 0

    assert %{base_run: base_run, variant_run: suggested_variant} =
             HydraAgent.SimLab.Simulations.latest_comparable_pair(study)

    assert base_run.id == run.id
    assert suggested_variant.id == variant_run.id

    variant_run_with_report = HydraAgent.SimLab.Simulations.get_run!(study, variant_run.id)

    assert Enum.any?(variant_run_with_report.forecast_report.assumptions, fn assumption ->
             assumption["statement"] =~ "Counterfactual assumption"
           end)

    locked_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert locked_dossier =~ "Duplicate it to preserve its forecast."
    assert locked_dossier =~ "Compare variant with base"

    comparison =
      conn
      |> get(
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/compare?base_run_id=#{run.id}&variant_run_id=#{variant_run.id}"
      )
      |> html_response(200)

    assert comparison =~ "What changed between the two runs?"
    assert comparison =~ "Base run"
    assert comparison =~ "Variant run"
    assert comparison =~ "Validate the variant"
    assert comparison =~ "explicit counterfactual assumption"

    report_path = "/lab/workspaces/#{workspace.id}/studies/#{study.id}/reports/#{run.id}"

    report = conn |> get(report_path) |> html_response(200)
    assert report =~ "Forecast report"
    assert report =~ "Validate next"
    assert report =~ "Grounding mix"
    assert report =~ "Replay protocol"
    assert report =~ "INPUT FINGERPRINT"

    calibration_conn =
      post(conn, "#{report_path}/calibrations", %{
        "calibration" => %{
          "metric" => "adopt",
          "actual_value" => "42",
          "unit" => "percent",
          "note" => "Measured after four weeks."
        }
      })

    assert redirected_to(calibration_conn) == report_path

    calibrated_report = conn |> get(report_path) |> html_response(200)
    assert calibrated_report =~ "What actually happened?"
    assert calibrated_report =~ "42%"
    assert calibrated_report =~ "Calibration review"

    export = conn |> get("#{report_path}/export.md") |> response(200)
    assert export =~ "# How will new managers react"
  end

  test "a researcher can draft transparent scenario options from the saved brief", %{conn: conn} do
    workspace = workspace_fixture()

    {:ok, study} =
      SimLab.create_study(%{
        workspace_id: workspace.id,
        title: "Launch decision",
        question: "How will customers react to the new launch?",
        target_audience: "customers",
        timeframe: "45 days"
      })

    before =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert before =~ "Draft from saved brief"
    assert before =~ "no numeric effects until review"

    draft_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenario-draft")

    assert redirected_to(draft_conn) ==
             "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    scenarios = Simulations.list_scenarios(study)
    assert length(scenarios) == 3
    assert Enum.any?(scenarios, &String.ends_with?(&1.name, "· Baseline"))

    assert Enum.all?(
             scenarios,
             &(&1.metadata["numeric_effects"] == "none_until_researcher_review")
           )
  end

  test "a no-data study can run from a visibly low-confidence assumption context", %{conn: conn} do
    workspace = workspace_fixture()

    {:ok, study} =
      SimLab.create_study(%{
        workspace_id: workspace.id,
        title: "No-data workflow",
        question: "How might people react to a new workflow?"
      })

    assumption_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/assumption-context")

    assert redirected_to(assumption_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    assumption_dossier =
      conn
      |> get("/lab/workspaces/#{workspace.id}/studies/#{study.id}")
      |> html_response(200)

    assert assumption_dossier =~ "Assumptions, kept visible."
    assert assumption_dossier =~ "assumption-only starting point"

    behavior_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/behavior-draft")

    assert redirected_to(behavior_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

    scenario_conn =
      post(conn, "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios", %{
        "scenario" => %{
          "name" => "New workflow",
          "description" => "A new workflow becomes available.",
          "event_day" => ["1"],
          "event_title" => ["Announcement"],
          "event_impact" => ["People begin evaluating the change."]
        }
      })

    assert redirected_to(scenario_conn) == "/lab/workspaces/#{workspace.id}/studies/#{study.id}"
    [scenario] = HydraAgent.SimLab.Simulations.list_scenarios(study)

    run_conn =
      post(
        conn,
        "/lab/workspaces/#{workspace.id}/studies/#{study.id}/scenarios/#{scenario.id}/run",
        %{
          "mode" => "small"
        }
      )

    assert redirected_to(run_conn) =~ "/observatory/"

    [queued_run] = HydraAgent.SimLab.Simulations.list_pending_runs(study)

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{run_id: queued_run.id})

    run = HydraAgent.SimLab.Simulations.latest_run(study)
    assert run.confidence == 0.25

    report_run = HydraAgent.SimLab.Simulations.get_run!(study, run.id)

    assert Enum.any?(report_run.forecast_report.assumptions, fn assumption ->
             assumption["statement"] =~ "assumption-only starting point"
           end)
  end
end
