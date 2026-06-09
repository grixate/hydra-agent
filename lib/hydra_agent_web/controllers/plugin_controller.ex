defmodule HydraAgentWeb.PluginController do
  use HydraAgentWeb, :controller

  alias HydraAgent.Plugins

  def schema(conn, _params) do
    json(conn, %{data: Plugins.manifest_schema()})
  end

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    plugins = Plugins.list_installations(workspace_id, status: params["status"])
    json(conn, %{data: Enum.map(plugins, &plugin_json/1)})
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)
    json(conn, %{data: plugin_json(plugin)})
  end

  def capabilities(conn, %{"workspace_id" => workspace_id} = params) do
    capabilities =
      Plugins.list_capabilities(workspace_id,
        kind: params["kind"],
        status: params["status"]
      )

    json(conn, %{data: Enum.map(capabilities, &capability_json/1)})
  end

  def client_contract(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: Plugins.client_contract(workspace_id)})
  end

  def client_surfaces(conn, %{"workspace_id" => workspace_id}) do
    json(conn, %{data: Plugins.enabled_client_surface_specs(workspace_id)})
  end

  def web_routes(conn, %{"workspace_id" => workspace_id}) do
    client_surfaces(conn, %{"workspace_id" => workspace_id})
  end

  def scan(conn, %{"workspace_id" => workspace_id, "path" => path} = params) do
    case Plugins.scan_path(workspace_id, path, params) do
      {:ok, scan} ->
        json(conn, %{data: scan_json(scan)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def scan(
        conn,
        %{"workspace_id" => workspace_id, "source_url" => source_url, "source_ref" => source_ref} =
          params
      ) do
    case Plugins.scan_git(workspace_id, source_url, source_ref, params) do
      {:ok, scan} ->
        json(conn, %{data: scan_json(scan)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error})
    end
  end

  def install(conn, %{"workspace_id" => workspace_id, "path" => path} = params) do
    case Plugins.install_from_path(workspace_id, path, params) do
      {:ok, plugin} ->
        conn |> put_status(:created) |> json(%{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def install(
        conn,
        %{"workspace_id" => workspace_id, "source_url" => source_url, "source_ref" => source_ref} =
          params
      ) do
    case Plugins.install_from_git(workspace_id, source_url, source_ref, params) do
      {:ok, plugin} ->
        conn |> put_status(:created) |> json(%{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def enable(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.enable_installation(plugin, params) do
      {:ok, plugin} ->
        json(conn, %{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def disable(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.disable_installation(plugin, params) do
      {:ok, plugin} ->
        json(conn, %{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def upgrade(conn, %{"workspace_id" => workspace_id, "id" => id, "path" => path} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.upgrade_from_path(plugin, path, params) do
      {:ok, plugin} ->
        json(conn, %{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def upgrade(
        conn,
        %{
          "workspace_id" => workspace_id,
          "id" => id,
          "source_url" => source_url,
          "source_ref" => source_ref
        } = params
      ) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.upgrade_from_git(plugin, source_url, source_ref, params) do
      {:ok, plugin} ->
        json(conn, %{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def uninstall(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.uninstall_installation(plugin, params) do
      {:ok, plugin} ->
        json(conn, %{data: plugin_json(plugin)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def doctor(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    json(conn, %{data: Plugins.doctor(plugin)})
  end

  def config(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)
    configuration = Plugins.get_configuration(plugin)

    json(conn, %{data: config_json(plugin, configuration)})
  end

  def update_config(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.update_configuration(plugin, params) do
      {:ok, configuration} ->
        json(conn, %{data: config_json(plugin, configuration)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def migration_plan(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.migration_plan(plugin, params) do
      {:ok, plan} ->
        json(conn, %{data: plan})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  def run_migrations(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    plugin = Plugins.get_installation_for_workspace!(workspace_id, id)

    case Plugins.run_migrations(plugin, params) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: error_json(error)})
    end
  end

  defp scan_json(scan) do
    %{
      source_type: scan["source_type"],
      source_path: scan["source_path"],
      manifest_path: scan["manifest_path"],
      manifest_digest: scan["manifest_digest"],
      manifest: scan["manifest"],
      warnings: scan["warnings"],
      capabilities: Enum.map(scan["capabilities"], &capability_attrs_json/1)
    }
  end

  defp plugin_json(plugin) do
    manifest = plugin.manifest || %{}
    permissions = plugin.permissions || %{}

    %{
      id: plugin.id,
      workspace_id: plugin.workspace_id,
      slug: plugin.slug,
      name: plugin.name,
      version: plugin.version,
      description: plugin.description,
      status: plugin.status,
      source_type: plugin.source_type,
      source_url: plugin.source_url,
      source_path: plugin.source_path,
      source_ref: plugin.source_ref,
      trust_level: plugin.trust_level,
      package_type: manifest["package_type"],
      manifest_digest: plugin.manifest_digest,
      permissions: permissions,
      env_refs: plugin.env_refs,
      api_scopes: permissions["api_scopes"] || [],
      config_schema: manifest["config_schema"] || %{},
      compatibility: manifest["compatibility"] || %{},
      dependencies: manifest["dependencies"] || [],
      approved_by: plugin.approved_by,
      approved_at: plugin.approved_at,
      metadata: plugin.metadata,
      capabilities: Enum.map(plugin.capabilities || [], &capability_json/1)
    }
  end

  defp capability_json(capability) do
    %{
      id: capability.id,
      plugin_installation_id: capability.plugin_installation_id,
      workspace_id: capability.workspace_id,
      kind: capability.kind,
      name: capability.name,
      status: capability.status,
      side_effect_class: capability.side_effect_class,
      spec: capability.spec,
      metadata: capability.metadata
    }
  end

  defp capability_attrs_json(attrs) do
    %{
      kind: attrs["kind"],
      name: attrs["name"],
      side_effect_class: attrs["side_effect_class"],
      spec: attrs["spec"],
      metadata: attrs["metadata"]
    }
  end

  defp config_json(plugin, configuration) do
    manifest = plugin.manifest || %{}

    %{
      plugin_installation_id: plugin.id,
      workspace_id: plugin.workspace_id,
      config: configuration.config || %{},
      config_schema: manifest["config_schema"] || %{},
      configured_by: configuration.configured_by,
      configured_at: configuration.configured_at,
      metadata: configuration.metadata || %{}
    }
  end

  defp error_json(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp error_json(error), do: error
end
