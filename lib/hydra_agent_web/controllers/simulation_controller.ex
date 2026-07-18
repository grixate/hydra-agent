defmodule HydraAgentWeb.SimulationController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Accounts, ProductFeatures, Repo, Simulations}
  alias HydraAgent.Runtime.Workspace
  alias HydraAgent.Simulations.Blueprints
  alias HydraAgentWeb.{SimulationCopy, SimulationInput}

  plug :load_locale

  def index(conn, params) do
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = select_workspace(conn, params["workspace_id"], workspaces, "viewer")

    render(conn, :index,
      page_title: t(conn, :simulations),
      workspaces: workspaces,
      workspace: workspace,
      simulations: if(workspace, do: Simulations.list_simulations(workspace.id), else: []),
      legacy_studies: if(workspace, do: Simulations.list_legacy_studies(workspace.id), else: []),
      can_create: workspace && authorized?(conn, workspace.id, "researcher")
    )
  end

  def new(conn, params) do
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = select_workspace(conn, params["workspace_id"], workspaces, "researcher")
    render_new(conn, workspace, workspaces, %{}, nil)
  end

  def create(conn, %{"simulation" => form} = params) do
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = select_workspace(conn, params["workspace_id"], workspaces, "researcher")

    with %Workspace{} <- workspace,
         {:ok, attrs} <- SimulationInput.normalize(form),
         {:ok, simulation} <-
           Simulations.create_simulation(workspace, conn.assigns[:current_user], attrs) do
      conn
      |> put_flash(:info, t(conn, :created))
      |> redirect(to: stage_path(simulation.id, :build, workspace.id, conn.assigns.locale))
    else
      nil -> not_found(conn)
      {:error, reason} -> render_new(conn, workspace, workspaces, form, reason)
    end
  end

  def create(conn, params) do
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = select_workspace(conn, params["workspace_id"], workspaces, "researcher")
    render_new(conn, workspace, workspaces, %{}, :invalid_input)
  end

  def show(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "viewer") do
      redirect(
        conn,
        to:
          stage_path(
            simulation.id,
            Simulations.current_stage(simulation),
            workspace.id,
            conn.assigns.locale
          )
      )
    else
      _ -> not_found(conn)
    end
  end

  def build(conn, params), do: render_stage(conn, params, :build)
  def context(conn, params), do: render_context(conn, params)
  def population(conn, params), do: render_population(conn, params)
  def run(conn, params), do: render_stage(conn, params, :run)
  def results(conn, params), do: render_stage(conn, params, :results)
  def compare(conn, params), do: render_stage(conn, params, :compare)

  def build_context(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.build_context_pack(simulation, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :context_assembled))
      |> redirect(to: stage_path(simulation.id, :context, workspace.id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  def research_context(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.queue_context_research(simulation, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :context_research_queued))
      |> redirect(to: stage_path(simulation.id, :context, workspace.id, conn.assigns.locale))
    else
      {:error, :research_not_configured} ->
        conn
        |> put_flash(:error, t(conn, :context_research_not_configured))
        |> redirect(
          to: stage_path(params["id"], :context, params["workspace_id"], conn.assigns.locale)
        )

      _ ->
        not_found(conn)
    end
  end

  def exclude_context_source(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.exclude_context_source(
             simulation,
             params["source_id"],
             conn.assigns[:current_user]
           ) do
      conn
      |> put_flash(:info, t(conn, :context_source_excluded))
      |> redirect(to: stage_path(simulation.id, :context, workspace.id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  def build_population(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.build_population_model(simulation, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :population_built))
      |> redirect(to: stage_path(simulation.id, :population, workspace.id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  def import_population(conn, params) do
    form = params["population_import"] || %{}

    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         %Plug.Upload{} = upload <- form["file"],
         {:ok, content} <- read_population_upload(upload),
         {:ok, _result} <-
           Simulations.import_population(
             simulation,
             conn.assigns[:current_user],
             upload.filename,
             content,
             Map.delete(form, "file")
           ) do
      conn
      |> put_flash(:info, t(conn, :population_imported))
      |> redirect(to: stage_path(simulation.id, :population, workspace.id, conn.assigns.locale))
    else
      {:error, {:population_import_invalid_rows, summary}} ->
        render_population(conn, params,
          status: :unprocessable_entity,
          import_preview: summary,
          import_form: Map.delete(form, "file")
        )

      _ ->
        conn
        |> put_flash(:error, t(conn, :population_import_failed))
        |> redirect(
          to: stage_path(params["id"], :population, params["workspace_id"], conn.assigns.locale)
        )
    end
  end

  def generate_persona(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.generate_persona_projection(
             simulation,
             params["agent_id"],
             conn.assigns[:current_user]
           ) do
      conn
      |> put_flash(:info, t(conn, :persona_generated))
      |> redirect(to: stage_path(simulation.id, :population, workspace.id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  def exclude_population_attribute(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, _result} <-
           Simulations.exclude_population_attribute(
             simulation,
             params["type_id"],
             params["attribute_key"],
             conn.assigns[:current_user]
           ) do
      conn
      |> put_flash(:info, t(conn, :population_attribute_removed))
      |> redirect(to: stage_path(simulation.id, :population, workspace.id, conn.assigns.locale))
    else
      {:error, :population_last_attribute} ->
        conn
        |> put_flash(:error, t(conn, :population_last_attribute))
        |> redirect(
          to: stage_path(params["id"], :population, params["workspace_id"], conn.assigns.locale)
        )

      _ ->
        not_found(conn)
    end
  end

  def duplicate(conn, params) do
    with {_workspace, simulation} <- fetch_simulation(conn, params, "researcher"),
         {:ok, copy} <- Simulations.duplicate_simulation(simulation, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :duplicated))
      |> redirect(to: stage_path(copy.id, :build, copy.workspace_id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  def archive(conn, params) do
    with {%Workspace{} = workspace, simulation} <-
           fetch_simulation(conn, params, "researcher"),
         {:ok, _archived} <-
           Simulations.archive_simulation(simulation, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :archived))
      |> redirect(to: index_path(workspace.id, conn.assigns.locale))
    else
      _ -> not_found(conn)
    end
  end

  defp render_new(conn, workspace, workspaces, form, reason) do
    conn = if reason, do: put_status(conn, :unprocessable_entity), else: conn

    render(conn, :new,
      page_title: t(conn, :new_simulation),
      workspace: workspace,
      workspaces: workspaces,
      blueprints: if(workspace, do: Blueprints.list_blueprints(workspace.id), else: []),
      form: stringify_form(form),
      error: if(reason, do: error_copy(conn, reason), else: nil),
      balanced_enabled: ProductFeatures.enabled?(:balanced_mode),
      deep_enabled: ProductFeatures.enabled?(:deep_mode),
      input_limits: SimulationInput.limits()
    )
  end

  defp render_stage(conn, params, stage) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "viewer") do
      stages = Simulations.list_build_stages(simulation)

      render(conn, stage_template(stage),
        page_title: simulation.title,
        workspace: workspace,
        simulation: simulation,
        stages: stages,
        stage: stage,
        can_edit: authorized?(conn, workspace.id, "researcher"),
        context_pack: simulation.active_context_pack,
        population_model: simulation.active_population_model,
        context_research_run: Simulations.latest_context_research_run(simulation),
        context_research_configured:
          HydraAgent.SimLab.Research.Providers.web_search_configured?(),
        ready_summary: Simulations.ready_summary(simulation)
      )
    else
      _ -> not_found(conn)
    end
  end

  defp render_context(conn, params) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "viewer") do
      render(conn, :context,
        page_title: t(conn, :context_title),
        workspace: workspace,
        simulation: simulation,
        context_pack: simulation.active_context_pack,
        context_research_run: Simulations.latest_context_research_run(simulation),
        context_research_configured:
          HydraAgent.SimLab.Research.Providers.web_search_configured?(),
        can_edit: authorized?(conn, workspace.id, "researcher")
      )
    else
      _ -> not_found(conn)
    end
  end

  defp render_population(conn, params, opts \\ []) do
    with {%Workspace{} = workspace, simulation} <- fetch_simulation(conn, params, "viewer") do
      conn =
        case Keyword.get(opts, :status) do
          nil -> conn
          status -> put_status(conn, status)
        end

      population_model = simulation.active_population_model

      render(conn, :population,
        page_title: t(conn, :population_title),
        workspace: workspace,
        simulation: simulation,
        population_model: population_model,
        persona_projections:
          if(population_model,
            do: Simulations.list_persona_projections(population_model),
            else: []
          ),
        can_edit: authorized?(conn, workspace.id, "researcher"),
        import_preview: Keyword.get(opts, :import_preview),
        import_form: Keyword.get(opts, :import_form, %{}),
        import_limits: HydraAgent.Simulations.PopulationImporter.limits()
      )
    else
      _ -> not_found(conn)
    end
  end

  defp stage_template(:build), do: :build
  defp stage_template(_stage), do: :stage

  defp fetch_simulation(conn, params, minimum_role) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], minimum_role),
         simulation when not is_nil(simulation) <-
           Simulations.get_simulation_for_workspace(workspace.id, params["id"]) do
      {workspace, simulation}
    else
      _ -> nil
    end
  end

  # Plug creates the temporary path inside the system upload directory. Reject
  # links and paths outside that boundary before reading the bounded payload.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_population_upload(%Plug.Upload{} = upload) do
    with {:ok, path} <- validated_upload_path(upload.path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.size <= HydraAgent.Simulations.PopulationImporter.limits().max_bytes,
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> {:error, :population_import_invalid_file}
    end
  end

  defp validated_upload_path(path) when is_binary(path) do
    path = Path.expand(path)
    upload_root = Path.expand(System.tmp_dir!())

    if path != upload_root and String.starts_with?(path, upload_root <> "/"),
      do: {:ok, path},
      else: {:error, :outside_upload_directory}
  end

  defp validated_upload_path(_path), do: {:error, :invalid_upload_path}

  defp select_workspace(conn, requested_id, workspaces, minimum_role) do
    fallback_id = Accounts.default_research_workspace_id(conn.assigns[:current_user])
    candidate_id = requested_id || fallback_id

    Enum.find(workspaces, fn workspace ->
      to_string(workspace.id) == to_string(candidate_id) and
        authorized?(conn, workspace.id, minimum_role)
    end)
  end

  defp fetch_workspace(_conn, nil, _minimum_role), do: nil

  defp fetch_workspace(conn, workspace_id, minimum_role) do
    if authorized?(conn, workspace_id, minimum_role),
      do: Repo.get(Workspace, normalize_id(workspace_id)),
      else: nil
  end

  defp authorized?(conn, workspace_id, minimum_role) do
    Accounts.workspace_authorized?(conn.assigns[:current_user], workspace_id, minimum_role)
  end

  defp error_copy(conn, reason)
       when reason in [
              :invalid_public_url,
              :too_many_urls
            ],
       do: t(conn, :invalid_url)

  defp error_copy(conn, reason)
       when reason in [
              :invalid_file,
              :invalid_json_file,
              :file_too_large,
              :too_many_files
            ],
       do: t(conn, :invalid_file)

  defp error_copy(conn, :mode_disabled), do: t(conn, :mode_disabled)
  defp error_copy(conn, :invalid_historical_cutoff), do: t(conn, :invalid_cutoff)
  defp error_copy(conn, _reason), do: t(conn, :invalid_form)

  defp stringify_form(form) when is_map(form) do
    Map.new(form, fn
      {key, %Plug.Upload{}} ->
        {to_string(key), nil}

      {key, uploads} when is_list(uploads) ->
        {to_string(key),
         if(Enum.all?(uploads, &match?(%Plug.Upload{}, &1)), do: [], else: uploads)}

      {key, value} ->
        {to_string(key), value}
    end)
  end

  defp stringify_form(_form), do: %{}

  defp load_locale(conn, _opts) do
    requested = conn.params["locale"] || get_session(conn, :locale) || preferred_locale(conn)
    locale = if requested in ["en", "ru"], do: requested, else: "en"

    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  defp preferred_locale(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> to_string()
    |> String.downcase()
    |> then(fn language -> if String.starts_with?(language, "ru"), do: "ru", else: "en" end)
  end

  defp t(conn, key), do: SimulationCopy.t(conn.assigns.locale, key)

  defp index_path(workspace_id, locale) do
    "/simulations?" <>
      URI.encode_query(%{"workspace_id" => workspace_id || "", "locale" => locale})
  end

  defp stage_path(id, stage, workspace_id, locale) do
    suffix = if stage == :build, do: "build", else: Atom.to_string(stage)

    "/simulations/#{id}/#{suffix}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp not_found(conn), do: send_resp(conn, :not_found, "Not found")
end
