defmodule HydraAgentWeb.SimLabController do
  use HydraAgentWeb, :controller

  alias HydraAgent.SimLab
  alias HydraAgent.SimLab.BehaviorExport
  alias HydraAgent.SimLab.Calibrations
  alias HydraAgent.SimLab.Costing
  alias HydraAgent.SimLab.Forecast
  alias HydraAgent.SimLab.Jobs
  alias HydraAgent.SimLab.Simulations
  alias HydraAgent.SimLab.Studies

  alias HydraAgent.SimLab.Research.{
    CodexCliTestProvider,
    Providers,
    PublicUrlFetcher,
    StudyParser,
    WebResearchPlanner
  }

  alias HydraAgent.Accounts
  alias HydraAgent.Runtime

  @max_local_document_bytes 1_000_000
  @allowed_local_document_extensions ~w(.txt .md .markdown .csv)
  @scenario_modifiers ~w(control_first_opt_in manager_recognition)

  plug :ensure_enabled
  plug :authorize_workspace_access

  plug HydraAgentWeb.Plugs.RateLimit,
       [scope: "sim_lab_research", limit: 12, window_seconds: 3_600, identity: :user_workspace]
       when action in [:start_codex_test_research, :start_web_research]

  plug HydraAgentWeb.Plugs.RateLimit,
       [scope: "sim_lab_ingestion", limit: 30, window_seconds: 3_600, identity: :user_workspace]
       when action in [:add_upload, :add_public_url]

  plug HydraAgentWeb.Plugs.RateLimit,
       [scope: "sim_lab_runs", limit: 60, window_seconds: 3_600, identity: :user_workspace]
       when action in [:run_scenario]

  def studies(conn, _params),
    do:
      render(conn, :studies,
        layout: false,
        study: SimLab.demo_study(),
        run: SimLab.demo_run(),
        page_title: "Simulation demo"
      )

  def workspace_entry(conn, _params) do
    case Accounts.default_research_workspace_id(conn.assigns[:current_user]) do
      nil -> redirect(conn, to: "/control")
      workspace_id -> redirect(conn, to: "/lab/workspaces/#{workspace_id}/studies")
    end
  end

  def workspace_studies(conn, %{"workspace_id" => workspace_id}) do
    workspace = Runtime.get_workspace!(workspace_id)

    render(conn, :workspace_studies,
      layout: false,
      workspace: workspace,
      studies: SimLab.list_studies(workspace.id),
      page_title: "#{workspace.name} studies"
    )
  end

  def create(conn, %{"workspace_id" => workspace_id, "study" => params}) do
    workspace = Runtime.get_workspace!(workspace_id)
    question = params |> Map.get("question", "") |> String.trim()

    attrs = %{
      workspace_id: workspace.id,
      title: present(params["title"]) || title_from_question(question),
      question: question,
      domain: present(params["domain"]),
      region: present(params["region"]),
      timeframe: present(params["timeframe"]),
      target_audience: present(params["target_audience"])
    }

    case SimLab.create_study(attrs) do
      {:ok, study} ->
        conn
        |> put_flash(:info, "Study created. Add evidence before you simulate.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, first_error(changeset) || "Add a study question to continue.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies")
    end
  end

  def workspace_show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    context_pack = Studies.active_context_pack(study)
    research_runs = Jobs.list_research_runs(study.id)

    render(conn, :workspace_study,
      layout: false,
      workspace: workspace,
      study: study,
      context_pack: context_pack,
      sources: Studies.list_sources(study),
      evidence: Studies.list_evidence(study),
      research_runs: research_runs,
      research_query_preview: research_query_preview(study),
      personas: Studies.list_personas(study),
      patterns: Studies.list_action_patterns(study),
      scenarios: Simulations.list_scenarios(study),
      scenario_run_counts: Simulations.scenario_run_counts(study),
      latest_run: Simulations.latest_run(study),
      completed_runs: Simulations.list_completed_runs(study),
      pending_runs: Simulations.list_pending_runs(study),
      compare_candidate: Simulations.latest_comparable_pair(study),
      codex_cli_test_enabled: CodexCliTestProvider.enabled?(),
      web_search_configured: Providers.web_search_configured?(),
      cost_options: Enum.map(["tiny", "small", "medium", "large"], &Costing.estimate/1),
      page_title: study.title
    )
  end

  def start_codex_test_research(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    if CodexCliTestProvider.enabled?() do
      start_research_job(conn, workspace, study, CodexCliTestProvider,
        success:
          "Codex test hypotheses are running from abstracted queries. This page updates automatically."
      )
    else
      conn
      |> put_flash(
        :error,
        "Local Codex testing is disabled. Start Hydra with HYDRA_SIM_CODEX_CLI_TESTING=1."
      )
      |> redirect(to: study_path(workspace, study))
    end
  end

  def start_web_research(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    if Providers.web_search_configured?() do
      start_research_job(conn, workspace, study, Providers.web_search(),
        success: "Advanced web research is running. This page updates automatically."
      )
    else
      conn
      |> put_flash(
        :error,
        "Configure Tavily or a compatible search endpoint before web research."
      )
      |> redirect(to: study_path(workspace, study))
    end
  end

  def export_behavior_model(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    markdown =
      BehaviorExport.markdown(
        study,
        Studies.list_personas(study),
        Studies.list_action_patterns(study)
      )

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=hydra-behavior-model-#{study.id}.md"
    )
    |> send_resp(200, markdown)
  end

  def add_note(conn, %{"workspace_id" => workspace_id, "id" => id, "note" => note_params}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case Studies.add_manual_note(study, note_params) do
      {:ok, _result} ->
        conn
        |> put_flash(:info, "Note added to the context pack. It remains marked for review.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :blank_note} ->
        conn
        |> put_flash(:error, "Write a note before adding it to the context pack.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The note could not be saved. Please try again.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def start_assumption_context(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case Studies.create_assumption_context(study) do
      {:ok, _result} ->
        conn
        |> put_flash(
          :info,
          "Assumption context started at low confidence. Add evidence whenever you have it."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :context_already_exists} ->
        conn
        |> put_flash(:error, "This study already has an active context pack.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def synthesize_context(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case Studies.synthesize_workspace_context(study) do
      {:ok, %{context_pack: context_pack}} ->
        conn
        |> put_flash(
          :info,
          "Context pack v#{context_pack.version} refreshed from stored workspace evidence. No web research was run."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :no_workspace_evidence} ->
        conn
        |> put_flash(:error, "Add a local note or document before refreshing the context pack.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def add_upload(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "document" => %{"file" => %Plug.Upload{} = upload} = document_params
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    with {:ok, text, extension} <- read_local_document(upload),
         {:ok, _result} <-
           Studies.add_uploaded_text(study, %{
             title:
               present(document_params["title"]) || Path.rootname(Path.basename(upload.filename)),
             filename: Path.basename(upload.filename),
             extension: extension,
             text: text
           }) do
      conn
      |> put_flash(:info, "Local document added to the context pack for review.")
      |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    else
      {:error, :unsupported_document} ->
        conn
        |> put_flash(:error, "Upload a small UTF-8 .txt, .md, .markdown, or .csv document.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :document_too_large} ->
        conn
        |> put_flash(:error, "Local documents are limited to 1 MB.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The local document could not be read. Try a UTF-8 text file.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def add_public_url(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "public_source" => source_params
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    uri = source_params["uri"] || ""

    with {:ok, fetched} <- PublicUrlFetcher.fetch(uri),
         {:ok, _result} <-
           Studies.add_public_web_source(study, %{
             uri: fetched.uri,
             title: source_params["title"] || fetched.title,
             text: fetched.text
           }) do
      conn
      |> put_flash(:info, "Public source added as external research for review.")
      |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    else
      {:error, :invalid_public_https_url} ->
        conn
        |> put_flash(:error, "Use a public HTTPS URL without login credentials.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :non_public_host} ->
        conn
        |> put_flash(:error, "Private, local, and unresolved hosts cannot be fetched.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The public source could not be fetched as a small text document.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def remove_source(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "source_id" => source_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case Studies.remove_local_source(study, source_id) do
      {:ok, _result} ->
        conn
        |> put_flash(:info, "Source and its derived evidence were removed.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That source is not available in this study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def review_evidence(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "evidence_id" => evidence_id,
        "decision" => decision
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    reviewer_id = conn.assigns.current_user && conn.assigns.current_user.id

    case Studies.review_evidence(study, evidence_id, decision, reviewer_id) do
      {:ok, _evidence} ->
        _ = Studies.synthesize_workspace_context(study)

        message =
          if decision == "reviewed",
            do: "Evidence marked reviewed. A new context pack now reflects it.",
            else: "Evidence dismissed. It will not ground generated behavior."

        conn |> put_flash(:info, message) |> redirect(to: study_path(workspace, study))

      {:error, :evidence_not_in_study} ->
        conn
        |> put_flash(:error, "That evidence item is not available in this study.")
        |> redirect(to: study_path(workspace, study))

      {:error, :invalid_review_decision} ->
        conn
        |> put_flash(:error, "Choose review or dismiss for this evidence item.")
        |> redirect(to: study_path(workspace, study))
    end
  end

  def add_persona(conn, %{"workspace_id" => workspace_id, "id" => id, "persona" => persona_params}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    attrs =
      persona_params
      |> Map.put_new("grounding_mix", %{"assumption" => 1.0})
      |> Map.put_new("confidence", 0.55)
      |> Map.put_new("status", "active")

    case Studies.add_persona(study, attrs) do
      {:ok, _result} ->
        conn
        |> put_flash(
          :info,
          "Behavior segment added. Its grounding is marked as an assumption until you link evidence."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :distribution_exceeds_population} ->
        conn
        |> put_flash(:error, "Persona weights cannot add up to more than 100%.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Complete the segment name, audience, and population weight to add it."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def generate_behavior_draft(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case SimLab.generate_behavior_draft(study) do
      {:ok, %{persona_count: persona_count, pattern_count: pattern_count}} ->
        conn
        |> put_flash(
          :info,
          "Generated #{persona_count} editable segments and #{pattern_count} directional action rules. Review their evidence links, assumptions, and probabilities before running a scenario."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :personas_already_exist} ->
        conn
        |> put_flash(
          :error,
          "This study already has behavior segments. Edit those instead of replacing them automatically."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def update_persona(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "persona_id" => persona_id,
        "persona" => persona_params
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    attrs = %{
      "name" => persona_params["name"],
      "segment" => persona_params["segment"],
      "distribution_weight" => persona_params["distribution_weight"],
      "confidence" => persona_params["confidence"],
      "goals" => present_list(persona_params["goals"]),
      "frictions" => present_list(persona_params["frictions"]),
      "triggers" => present_list(persona_params["triggers"]),
      "trust_factors" => present_list(persona_params["trust_factors"]),
      "decision_style" => present(persona_params["decision_style"]),
      "likely_actions" => present_list(persona_params["likely_actions"]),
      "editable_notes" => present(persona_params["editable_notes"]),
      "evidence_refs" => present_list(persona_params["evidence_refs"])
    }

    case Studies.update_persona(study, persona_id, attrs) do
      {:ok, _result} ->
        conn
        |> put_flash(
          :info,
          "Behavior segment revised. Its new version will be used in future runs."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :distribution_exceeds_population} ->
        conn
        |> put_flash(:error, "Persona weights cannot add up to more than 100%.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :evidence_not_in_study} ->
        conn
        |> put_flash(:error, "Choose evidence that belongs to this study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Complete the segment details before saving this revision.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def add_pattern(conn, %{"workspace_id" => workspace_id, "id" => id, "pattern" => pattern_params}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    persona_id = pattern_params["persona_id"]

    attrs = %{
      "name" => pattern_params["name"],
      "condition" => pattern_params["condition"],
      "interpretation" => "Recorded as an explicit assumption pending evidence review.",
      "motivation" => pattern_params["motivation"],
      "likely_action" => pattern_params["likely_action"],
      "base_probability" => pattern_params["base_probability"],
      "confidence" => pattern_params["confidence"] || "0.55",
      "evidence_refs" => [],
      "assumption_refs" => ["manual_pattern"],
      "executable_rule" => %{"origin" => "manual_pattern"}
    }

    case Studies.add_action_pattern(study, persona_id, attrs) do
      {:ok, _result} ->
        conn
        |> put_flash(:info, "Action pattern added and labelled as an assumption.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :persona_not_in_study} ->
        conn
        |> put_flash(:error, "Choose a segment that belongs to this study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Complete the action pattern details before adding it.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def update_pattern(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "pattern_id" => pattern_id,
        "pattern" => pattern_params
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    attrs = %{
      "name" => pattern_params["name"],
      "condition" => pattern_params["condition"],
      "interpretation" => pattern_params["interpretation"],
      "motivation" => pattern_params["motivation"],
      "likely_action" => pattern_params["likely_action"],
      "base_probability" => pattern_params["base_probability"],
      "confidence" => pattern_params["confidence"],
      "blockers" => supporting_factors(pattern_params["blocker"]),
      "amplifiers" => supporting_factors(pattern_params["amplifier"]),
      "executable_rule" => %{"origin" => "manual_review"},
      "evidence_refs" => present_list(pattern_params["evidence_refs"])
    }

    case Studies.update_action_pattern(study, pattern_id, pattern_params["persona_id"], attrs) do
      {:ok, _result} ->
        conn
        |> put_flash(:info, "Action rule revised. Future runs will use this version.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :evidence_not_in_study} ->
        conn
        |> put_flash(:error, "Choose evidence that belongs to this study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Complete the rule and choose a segment from this study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def add_scenario(conn, %{"workspace_id" => workspace_id, "id" => id, "scenario" => params}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    attrs = %{
      name: params["name"],
      description: params["description"],
      forecast_horizon: present(params["forecast_horizon"]),
      events: scenario_events(params),
      success_metrics: present_list(params["success_metric"]),
      available_actions: ["adopt", "resist", "ignore", "share"],
      metadata:
        Map.merge(%{"created_in" => "workspace_study"}, scenario_modifier_metadata(params))
    }

    case Simulations.create_scenario(study, attrs) do
      {:ok, _scenario} ->
        conn
        |> put_flash(:info, "Scenario saved. Choose a run size when you are ready to observe it.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Add a scenario name and the change you want to study.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def generate_scenario_draft(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    context_pack = Studies.active_context_pack(study)

    case SimLab.generate_scenario_draft(study, context_pack) do
      {:ok, %{generated: generated}} ->
        conn
        |> put_flash(
          :info,
          "Drafted #{length(generated)} scenario options from the saved brief. Review every timeline before a run."
        )
        |> redirect(to: study_path(workspace, study))

      {:error, :scenarios_already_exist} ->
        conn
        |> put_flash(
          :error,
          "This study already has scenarios. Refine or duplicate those instead."
        )
        |> redirect(to: study_path(workspace, study))
    end
  end

  def update_scenario(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "scenario_id" => scenario_id,
        "scenario" => params
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    attrs = %{
      name: params["name"],
      description: params["description"],
      forecast_horizon: present(params["forecast_horizon"]),
      events: scenario_events(params),
      success_metrics: present_list(params["success_metric"]),
      metadata: scenario_modifier_metadata(params)
    }

    case Simulations.update_scenario(study, scenario_id, attrs) do
      {:ok, _scenario} ->
        conn
        |> put_flash(
          :info,
          "Scenario refined. Its next run will use this version of the timeline."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :scenario_has_runs} ->
        conn
        |> put_flash(
          :error,
          "This scenario already has a run. Duplicate it to preserve the earlier forecast."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Add a scenario name and a clear change before saving.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def create_variant(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "scenario_id" => scenario_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    scenario = Simulations.get_scenario!(study, scenario_id)

    case Simulations.create_variant(study, scenario) do
      {:ok, variant} ->
        conn
        |> put_flash(:info, "Created #{variant.name}. Adjust its scenario before running it.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "The scenario variant could not be created.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def run_scenario(
        conn,
        %{"workspace_id" => workspace_id, "id" => id, "scenario_id" => scenario_id} = params
      ) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    scenario = Simulations.get_scenario!(study, scenario_id)
    context_pack = Studies.active_context_pack(study)
    mode = normalize_run_mode(params["mode"])
    budget_cap_usd = Costing.estimate(mode).high_usd

    with %{} = context_pack <- context_pack,
         {:ok, compiled} <-
           SimLab.build_simulation_input(
             Studies.list_personas(study),
             Studies.list_action_patterns(study),
             scenario,
             mode: mode
           ),
         {:ok, persisted} <-
           Simulations.queue_run(study, scenario, context_pack, compiled.input,
             mode: mode,
             budget_cap_usd: budget_cap_usd,
             coverage: compiled.coverage,
             confidence: simulation_confidence(compiled.coverage, context_pack),
             assumptions:
               simulation_assumptions(compiled.coverage) ++
                 context_assumptions(context_pack) ++ scenario_assumptions(scenario)
           ) do
      conn
      |> put_flash(:info, "Simulation queued. Hydra saved the replay input before execution.")
      |> redirect(
        to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}/observatory/#{persisted.run.id}"
      )
    else
      nil ->
        conn
        |> put_flash(:error, "Add a context note before starting a run.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :no_personas} ->
        conn
        |> put_flash(:error, "Add at least one behavioral segment before starting a run.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, :budget_cap_exceeded} ->
        conn
        |> put_flash(
          :error,
          "The run was not started because its authorized provider budget was exceeded."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "The simulation could not be prepared. Review the scenario and try again."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def workspace_observatory(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "run_id" => run_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)

    if run.status == "completed" do
      patterns = Simulations.patterns_for_run(run, Studies.list_action_patterns(study))

      render(conn, :workspace_observatory,
        layout: false,
        workspace: workspace,
        study: study,
        run: run,
        scenario: run.scenario,
        snapshots: observable_snapshots(Simulations.replay_snapshots(run), run.scenario.events),
        pattern_insights: observatory_pattern_insights(patterns),
        page_title: "Observatory · #{study.title}"
      )
    else
      render(conn, :workspace_run_pending,
        layout: false,
        workspace: workspace,
        study: study,
        run: run,
        scenario: run.scenario,
        page_title: "Preparing run · #{study.title}"
      )
    end
  end

  def create_control_first_variant(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "run_id" => run_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)

    case Simulations.create_control_first_variant(study, run) do
      {:ok, scenario} ->
        conn
        |> put_flash(
          :info,
          "Prepared #{scenario.name} as an assumption-marked counterfactual. Refine it, then run it separately."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "The counterfactual variant could not be prepared.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def cancel_run(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "run_id" => run_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)

    case Simulations.cancel_run(study, run_id) do
      {:ok, _run} ->
        conn
        |> put_flash(
          :info,
          "Simulation cancelled. No replay snapshots or forecast were published."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "This run is no longer waiting and cannot be cancelled.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}")
    end
  end

  def workspace_report(conn, %{"workspace_id" => workspace_id, "id" => id, "run_id" => run_id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)
    calibrations = Calibrations.list(run)

    render(conn, :workspace_report,
      layout: false,
      workspace: workspace,
      study: study,
      run: run,
      report: run.forecast_report,
      calibrations: calibrations,
      calibration_review: Calibrations.review(calibrations),
      calibration_proposals: Calibrations.proposals(study, run),
      page_title: "Forecast · #{study.title}"
    )
  end

  def workspace_compare(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "base_run_id" => base_run_id,
        "variant_run_id" => variant_run_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    comparison = Simulations.compare_runs(study, base_run_id, variant_run_id)

    render(conn, :workspace_compare,
      layout: false,
      workspace: workspace,
      study: study,
      comparison: comparison,
      page_title: "Compare runs · #{study.title}"
    )
  end

  def export_report(conn, %{"workspace_id" => workspace_id, "id" => id, "run_id" => run_id}) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=hydra-simulation-report-#{run.id}.md"
    )
    |> send_resp(200, run.forecast_report.markdown_body)
  end

  def record_calibration(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "run_id" => run_id,
        "calibration" => attrs
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)

    case SimLab.record_calibration(study, run, normalize_calibration_attrs(attrs)) do
      {:ok, _record} ->
        conn
        |> put_flash(
          :info,
          "Actual outcome recorded. The forecast delta is now part of this run's review trail."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}/reports/#{run.id}")

      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Enter an actual outcome between 0% and 100% for a forecasted metric."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}/reports/#{run.id}")
    end
  end

  def apply_calibration_proposal(conn, %{
        "workspace_id" => workspace_id,
        "id" => id,
        "run_id" => run_id,
        "pattern_id" => pattern_id
      }) do
    workspace = Runtime.get_workspace!(workspace_id)
    study = Studies.get_study!(workspace.id, id)
    run = Simulations.get_run!(study, run_id)

    case Calibrations.apply_proposal(study, run, pattern_id) do
      {:ok, _pattern} ->
        conn
        |> put_flash(
          :info,
          "Confidence revision applied to future runs. This forecast remains unchanged."
        )
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}/reports/#{run.id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That calibration proposal is no longer available.")
        |> redirect(to: "/lab/workspaces/#{workspace.id}/studies/#{study.id}/reports/#{run.id}")
    end
  end

  def show(conn, _params) do
    study = SimLab.demo_study()
    run = SimLab.demo_run()

    forecast =
      Forecast.build(run, study,
        assumptions: ["Manager recognition is assumed to be meaningful."]
      )

    render(conn, :study,
      layout: false,
      study: study,
      run: run,
      forecast: forecast,
      page_title: "#{study.title} · Demo"
    )
  end

  def observatory(conn, _params),
    do:
      render(conn, :observatory,
        layout: false,
        study: SimLab.demo_study(),
        run: SimLab.demo_run(),
        page_title: "Observatory · Demo"
      )

  def demo_export_forecast(conn, _params) do
    study = SimLab.demo_study()
    run = SimLab.demo_run()

    forecast =
      Forecast.build(run, study,
        assumptions: ["Manager recognition is assumed to be meaningful."]
      )

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("content-disposition", "attachment; filename=hydra-demo-forecast.md")
    |> send_resp(:ok, forecast.markdown_body)
  end

  defp ensure_enabled(conn, _opts) do
    if Application.get_env(:hydra_agent, :sim_lab_enabled, false) do
      conn
    else
      conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp authorize_workspace_access(%{params: %{"workspace_id" => workspace_id}} = conn, _opts) do
    minimum_role = if conn.method in ["GET", "HEAD"], do: "viewer", else: "researcher"

    if Accounts.workspace_authorized?(conn.assigns[:current_user], workspace_id, minimum_role) do
      conn
    else
      conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp authorize_workspace_access(conn, _opts), do: conn

  defp title_from_question(""), do: "Untitled study"

  defp title_from_question(question) do
    title = question |> String.replace(~r/[?!.]+\z/, "") |> String.trim()

    if String.length(title) <= 80 do
      title
    else
      shortened = String.slice(title, 0, 76)

      shortened
      |> String.split()
      |> Enum.drop(-1)
      |> Enum.join(" ")
      |> case do
        "" -> shortened
        words -> words
      end
      |> Kernel.<>("…")
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_), do: nil

  # Plug creates and owns `path`; clients control only filename/content type.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local_document(%Plug.Upload{filename: filename, path: path}) do
    extension = filename |> Path.extname() |> String.downcase()

    with true <- extension in @allowed_local_document_extensions,
         {:ok, %{size: size}} when size <= @max_local_document_bytes <- File.stat(path),
         {:ok, text} <- File.read(path),
         true <- String.valid?(text) and not String.contains?(text, <<0>>) do
      {:ok, text, extension}
    else
      false -> {:error, :unsupported_document}
      {:ok, %{size: _size}} -> {:error, :document_too_large}
      {:error, _reason} -> {:error, :unreadable_document}
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.values()
    |> List.flatten()
    |> List.first()
  end

  defp scenario_events(params) do
    days = List.wrap(params["event_day"])
    titles = List.wrap(params["event_title"])
    impacts = List.wrap(params["event_impact"])
    actions = List.wrap(params["event_action"])
    deltas = List.wrap(params["event_delta"])

    days
    |> Enum.zip(titles)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{day, title}, index} ->
      case {present(day), present(title)} do
        {nil, _} ->
          []

        {_, nil} ->
          []

        {day, title} ->
          action_effects =
            case {Enum.at(actions, index), Enum.at(deltas, index)} do
              {action, delta} when action in ~w(adopt resist ignore share) ->
                %{action => parse_probability_delta(delta)}

              _ ->
                %{}
            end

          [
            %{
              "day" => day,
              "title" => title,
              "impact" => Enum.at(impacts, index) || "Behavior may shift.",
              "action_effects" => action_effects
            }
          ]
      end
    end)
  end

  defp parse_probability_delta(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number |> max(-0.5) |> min(0.5)
      _ -> 0.0
    end
  end

  defp parse_probability_delta(value) when is_number(value), do: value * 1.0
  defp parse_probability_delta(_value), do: 0.0

  defp normalize_calibration_attrs(%{"unit" => "percent", "actual_value" => value} = attrs)
       when is_binary(value) do
    normalized_value =
      case Float.parse(value) do
        {number, ""} -> number / 100
        _ -> value
      end

    attrs
    |> Map.put("actual_value", normalized_value)
    |> Map.delete("unit")
  end

  defp normalize_calibration_attrs(attrs), do: attrs

  defp present_list(value),
    do: value |> List.wrap() |> Enum.map(&present/1) |> Enum.reject(&is_nil/1)

  defp supporting_factors(value) do
    value
    |> present_list()
    |> Enum.map(&%{"statement" => &1})
  end

  defp simulation_confidence(
         %{
           unmodelled_population: remainder,
           grounded_rule_ratio: grounded_rules,
           mechanism_event_ratio: mechanism_events
         },
         context_pack
       ) do
    model_confidence =
      (0.35 + grounded_rules * 0.15 + mechanism_events * 0.15 - remainder * 0.4)
      |> max(0.2)
      |> min(0.65)

    context_confidence = context_pack.confidence || model_confidence

    Float.round(min(model_confidence, context_confidence), 2)
  end

  defp simulation_assumptions(coverage) do
    []
    |> maybe_add_assumption(
      coverage.unmodelled_population > 0.001,
      "#{round(coverage.unmodelled_population * 100)}% of the population has no explicit behavioral segment yet."
    )
    |> maybe_add_assumption(
      coverage.mechanism_event_ratio < 1.0,
      "Some timeline events have no explicit probability effect and are narrative-only."
    )
  end

  defp maybe_add_assumption(assumptions, true, statement), do: assumptions ++ [statement]
  defp maybe_add_assumption(assumptions, false, _statement), do: assumptions

  defp context_assumptions(context_pack) do
    case Map.get(context_pack.summary || %{}, "research_status") do
      "assumption_start" ->
        [
          "No direct or external research evidence has been added; this forecast is an assumption-only starting point."
        ]

      "no_local_evidence" ->
        [
          "All local evidence was removed; this forecast is again an assumption-only starting point."
        ]

      status
      when status in ["synthetic_test_hypotheses", "partial_synthetic_test_hypotheses"] ->
        [
          "Codex CLI generated synthetic test hypotheses only; no external source was retrieved or verified."
        ]

      _ ->
        []
    end
  end

  defp start_research_job(conn, workspace, study, provider, opts) do
    attrs = research_attributes(study)

    research_opts = %{
      provider: provider,
      private_entities: private_study_entities(study)
    }

    case SimLab.start_research(study, study.question, attrs, research_opts) do
      {:ok, _pid} ->
        conn
        |> put_flash(:info, Keyword.fetch!(opts, :success))
        |> redirect(to: study_path(workspace, study))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Research could not be started. Check the local provider setup.")
        |> redirect(to: study_path(workspace, study))
    end
  end

  defp study_path(workspace, study),
    do: "/lab/workspaces/#{workspace.id}/studies/#{study.id}"

  defp research_query_preview(study) do
    study.question
    |> StudyParser.parse(research_attributes(study))
    |> WebResearchPlanner.plan(private_entities: private_study_entities(study))
  end

  defp research_attributes(study) do
    %{
      domain: study.domain,
      region: study.region,
      language: study.language || "en",
      timeframe: study.timeframe,
      target_audience: study.target_audience
    }
  end

  # Brief fields may contain unreleased names or market labels, so every exact
  # value is abstracted before the provider receives a query. Local source text
  # never enters the query planner.
  defp private_study_entities(study) do
    [study.title, study.domain, study.target_audience, study.region, study.timeframe]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp scenario_assumptions(scenario) do
    case Map.get(scenario.metadata || %{}, "simulation_modifier") do
      "control_first_opt_in" ->
        [
          "Counterfactual assumption: explicit opt-in control moves resistance-labelled rules toward adoption. Validate this with a real pilot."
        ]

      "manager_recognition" ->
        [
          "Scenario assumption: credible manager recognition moves hesitation-labelled rules toward adoption. Validate this with a real pilot."
        ]

      _ ->
        []
    end
  end

  defp scenario_modifier_metadata(params) do
    case Map.fetch(params, "simulation_modifier") do
      {:ok, modifier} when modifier in @scenario_modifiers ->
        %{"simulation_modifier" => modifier}

      {:ok, _modifier} ->
        %{"simulation_modifier" => nil}

      :error ->
        %{}
    end
  end

  defp normalize_run_mode(mode) when mode in ["tiny", "small", "medium", "large"], do: mode
  defp normalize_run_mode(_), do: "small"

  defp observable_snapshots(snapshots, events) do
    Enum.map(snapshots, fn snapshot ->
      event = Enum.at(events, snapshot.tick - 1) || %{}

      %{
        tick: snapshot.tick,
        label: snapshot.label,
        day: event["day"] || event[:day] || snapshot.tick,
        event: event["title"] || event[:title] || snapshot.label,
        clusters: snapshot.clusters["groups"] || [],
        metrics: snapshot.metrics,
        cost: snapshot.cost
      }
    end)
  end

  defp observatory_pattern_insights(patterns) do
    Enum.map(patterns, fn pattern ->
      %{
        name: pattern_value(pattern, :name),
        condition: pattern_value(pattern, :condition),
        interpretation: pattern_value(pattern, :interpretation),
        motivation: pattern_value(pattern, :motivation),
        grounding_level: pattern_value(pattern, :grounding_level),
        evidence_count: length(pattern_value(pattern, :evidence_refs) || []),
        assumption_count: length(pattern_value(pattern, :assumption_refs) || [])
      }
    end)
  end

  defp pattern_value(pattern, key) when is_map(pattern),
    do: Map.get(pattern, key) || Map.get(pattern, to_string(key))

  defp pattern_value(_pattern, _key), do: nil
end
