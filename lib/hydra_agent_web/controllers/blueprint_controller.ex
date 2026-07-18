defmodule HydraAgentWeb.BlueprintController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Accounts, ProductFeatures, Repo}
  alias HydraAgent.Runtime.Workspace
  alias HydraAgent.Simulations.{BlueprintManifest, Blueprints}
  alias HydraAgentWeb.BlueprintCopy

  plug :load_locale

  def index(conn, params) do
    workspaces = Accounts.list_research_workspaces(conn.assigns[:current_user])
    workspace = select_workspace(conn, params["workspace_id"], workspaces, "viewer")

    blueprints = if workspace, do: Blueprints.list_blueprints(workspace.id), else: []
    can_edit = workspace && authorized?(conn, workspace.id, "researcher")

    render(conn, :index,
      page_title: t(conn, :library_eyebrow),
      workspaces: workspaces,
      workspace: workspace,
      blueprints: blueprints,
      can_edit: can_edit,
      import_enabled: ProductFeatures.enabled?(:blueprint_import)
    )
  end

  def show(conn, params), do: render_blueprint(conn, params, nil)

  def duplicate(conn, %{"id" => id, "workspace_id" => workspace_id} = params) do
    with %Workspace{} = workspace <- fetch_workspace(conn, workspace_id, "researcher"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, id),
         {:ok, copy} <-
           Blueprints.duplicate_blueprint(blueprint, workspace, conn.assigns[:current_user]) do
      conn
      |> put_flash(:info, t(conn, :duplicated_ok))
      |> redirect(to: show_path(copy.id, workspace.id, conn.assigns.locale))
    else
      {:error, :forbidden} -> forbidden(conn, params)
      {:error, _reason} -> action_error(conn, params)
      _ -> not_found(conn)
    end
  end

  def edit(conn, %{"id" => id} = params) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], "researcher"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, id) do
      if blueprint.built_in do
        conn
        |> put_flash(:error, t(conn, :read_only_notice))
        |> redirect(to: show_path(blueprint.id, workspace.id, conn.assigns.locale))
      else
        render_edit(conn, workspace, blueprint, nil, nil)
      end
    else
      _ -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id, "blueprint" => form} = params) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], "researcher"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, id),
         false <- blueprint.built_in,
         {:ok, manifest} <- BlueprintManifest.parse(form["manifest_yaml"] || ""),
         manifest <-
           manifest
           |> Map.put("id", blueprint.slug)
           |> Map.put("version", String.trim(form["version"] || "")),
         instructions when is_map(instructions) <- form["instructions"],
         {:ok, updated} <-
           Blueprints.create_version(blueprint, conn.assigns[:current_user], %{
             manifest: manifest,
             instructions: instructions,
             schemas: blueprint.active_version.schemas,
             examples: blueprint.active_version.examples,
             readme: blueprint.active_version.readme
           }) do
      conn
      |> put_flash(:info, t(conn, :saved_ok))
      |> redirect(to: show_path(updated.id, workspace.id, conn.assigns.locale))
    else
      true ->
        action_error(conn, params)

      {:error, reason} ->
        workspace = fetch_workspace(conn, params["workspace_id"], "researcher")
        blueprint = workspace && Blueprints.get_blueprint_for_workspace(workspace.id, id)

        if workspace && blueprint do
          render_edit(conn, workspace, blueprint, form, reason)
        else
          not_found(conn)
        end

      _ ->
        action_error(conn, params)
    end
  end

  def test(conn, params), do: render_blueprint_test(conn, params)

  def export(conn, %{"id" => id} = params) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], "viewer"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, id),
         {:ok, package} <- Blueprints.export_blueprint(blueprint) do
      send_download(conn, {:binary, package.binary},
        filename: package.filename,
        content_type: "application/zip"
      )
    else
      _ -> not_found(conn)
    end
  end

  def import(conn, params) do
    if ProductFeatures.enabled?(:blueprint_import) do
      import_enabled(conn, params)
    else
      import_disabled(conn, params)
    end
  end

  # Plug creates and owns `upload.path`; clients control only filename and content.
  # The importer then inspects the ZIP fail-closed before extracting it in memory.
  # sobelow_skip ["Traversal.FileModule"]
  defp import_enabled(
         conn,
         %{"workspace_id" => workspace_id, "package" => %Plug.Upload{} = upload} = params
       ) do
    with %Workspace{} = workspace <- fetch_workspace(conn, workspace_id, "researcher"),
         true <- String.ends_with?(String.downcase(upload.filename), ".hydra-blueprint"),
         {:ok, stat} <- File.stat(upload.path),
         true <- stat.size <= 2_000_000,
         {:ok, binary} <- File.read(upload.path),
         {:ok, blueprint} <-
           Blueprints.import_blueprint(workspace, conn.assigns[:current_user], binary) do
      conn
      |> put_flash(:info, t(conn, :imported_ok))
      |> redirect(to: show_path(blueprint.id, workspace.id, conn.assigns.locale))
    else
      {:error, :forbidden} -> forbidden(conn, params)
      _ -> import_error(conn, params)
    end
  end

  defp import_enabled(conn, params), do: import_error(conn, params)

  defp render_blueprint(conn, %{"id" => id} = params, test_result) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], "viewer"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, id) do
      render(conn, :show,
        page_title: localized(blueprint.name, conn.assigns.locale),
        workspace: workspace,
        blueprint: blueprint,
        can_edit: authorized?(conn, workspace.id, "researcher"),
        test_result: test_result
      )
    else
      _ -> not_found(conn)
    end
  end

  defp render_blueprint_test(conn, params) do
    with %Workspace{} = workspace <- fetch_workspace(conn, params["workspace_id"], "viewer"),
         blueprint when not is_nil(blueprint) <-
           Blueprints.get_blueprint_for_workspace(workspace.id, params["id"]),
         {:ok, result} <- Blueprints.test_blueprint(blueprint) do
      render(conn, :show,
        page_title: localized(blueprint.name, conn.assigns.locale),
        workspace: workspace,
        blueprint: blueprint,
        can_edit: authorized?(conn, workspace.id, "researcher"),
        test_result: result
      )
    else
      _ -> action_error(conn, params)
    end
  end

  defp render_edit(conn, workspace, blueprint, form, reason) do
    version = blueprint.active_version
    conn = if reason, do: put_status(conn, :unprocessable_entity), else: conn

    render(conn, :edit,
      page_title: t(conn, :edit_title),
      workspace: workspace,
      blueprint: blueprint,
      version: version,
      source_version: Blueprints.source_version(blueprint),
      form: form,
      proposed_version: (form && form["version"]) || next_patch(version.version),
      manifest_yaml:
        (form && form["manifest_yaml"]) || BlueprintManifest.encode(version.manifest),
      instructions: (form && form["instructions"]) || version.instructions,
      error: if(reason, do: t(conn, :validation_error), else: nil)
    )
  end

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

  defp forbidden(conn, params) do
    conn
    |> put_flash(:error, t(conn, :forbidden))
    |> redirect(to: index_path(params["workspace_id"], conn.assigns.locale))
  end

  defp action_error(conn, params) do
    conn
    |> put_flash(:error, t(conn, :validation_error))
    |> redirect(to: index_path(params["workspace_id"], conn.assigns.locale))
  end

  defp import_error(conn, params) do
    conn
    |> put_flash(:error, t(conn, :invalid_package))
    |> redirect(to: index_path(params["workspace_id"], conn.assigns.locale))
  end

  defp import_disabled(conn, params) do
    conn
    |> put_flash(:error, t(conn, :import_disabled))
    |> redirect(to: index_path(params["workspace_id"], conn.assigns.locale))
  end

  defp not_found(conn), do: send_resp(conn, :not_found, "Not found")

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

  defp next_patch(version) do
    case Version.parse(version) do
      {:ok, parsed} -> "#{parsed.major}.#{parsed.minor}.#{parsed.patch + 1}"
      :error -> "1.0.0"
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp t(conn, key), do: BlueprintCopy.t(conn.assigns.locale, key)
  defp localized(value, locale), do: value[locale] || value["en"] || "Blueprint"

  defp index_path(workspace_id, locale) do
    "/blueprints?" <>
      URI.encode_query(%{"workspace_id" => workspace_id || "", "locale" => locale})
  end

  defp show_path(id, workspace_id, locale) do
    "/blueprints/#{id}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end
end
