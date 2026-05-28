defmodule HydraAgentWeb.ProviderController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Providers, Runtime}

  def index(conn, %{"workspace_id" => workspace_id}) do
    providers = Runtime.list_providers(workspace_id)
    json(conn, %{data: Enum.map(providers, &provider_json/1)})
  end

  def credential_pools(conn, %{"workspace_id" => workspace_id}) do
    pools = Runtime.list_credential_pools(workspace_id)
    json(conn, %{data: Enum.map(pools, &credential_pool_json/1)})
  end

  def create_credential_pool(conn, %{"workspace_id" => workspace_id} = params) do
    params = Map.put(params, "workspace_id", workspace_id)

    case Runtime.create_credential_pool(params) do
      {:ok, pool} ->
        conn
        |> put_status(:created)
        |> json(%{data: credential_pool_json(pool)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def create_credential_pool_item(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    pool = Runtime.get_credential_pool_for_workspace!(workspace_id, id)

    case Runtime.create_credential_pool_item(pool, params) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> json(%{data: credential_pool_item_json(item)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def create_credential_pool_item(conn, %{"id" => id} = params) do
    pool = Runtime.get_credential_pool!(id)

    case Runtime.create_credential_pool_item(pool, params) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> json(%{data: credential_pool_item_json(item)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def show(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    provider = Runtime.get_provider_for_workspace!(workspace_id, id)
    json(conn, %{data: provider_json(provider)})
  end

  def show(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)
    json(conn, %{data: provider_json(provider)})
  end

  def create(conn, %{"workspace_id" => workspace_id} = params) do
    do_create(conn, Map.put(params, "workspace_id", workspace_id))
  end

  def create(conn, params) do
    do_create(conn, params)
  end

  defp do_create(conn, params) do
    case Runtime.create_provider(params) do
      {:ok, provider} ->
        conn
        |> put_status(:created)
        |> json(%{data: provider_json(provider)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def health(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    provider = Runtime.get_provider_for_workspace!(workspace_id, id)
    render_health(conn, provider)
  end

  def health(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)
    render_health(conn, provider)
  end

  defp render_health(conn, provider) do
    case Providers.health(provider) do
      :ok ->
        json(conn, %{data: %{status: "ok", provider: provider_json(provider)}})

      {:error, error} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{data: %{status: "error", provider: provider_json(provider), error: error}})
    end
  end

  def models(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    provider = Runtime.get_provider_for_workspace!(workspace_id, id)
    render_models(conn, provider)
  end

  def models(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)
    render_models(conn, provider)
  end

  defp render_models(conn, provider) do
    case Providers.models(provider) do
      {:ok, models} ->
        json(conn, %{data: models})

      {:error, error} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{errors: error})
    end
  end

  defp provider_json(provider) do
    %{
      id: provider.id,
      workspace_id: provider.workspace_id,
      name: provider.name,
      kind: provider.kind,
      base_url: provider.base_url,
      model: provider.model,
      api_key_env: provider.api_key_env,
      credential_pool_id: provider.credential_pool_id,
      credential_pool: assoc_json(provider, :credential_pool, &credential_pool_json/1),
      enabled: provider.enabled,
      metadata: provider.metadata
    }
  end

  defp credential_pool_json(pool) do
    %{
      id: pool.id,
      workspace_id: pool.workspace_id,
      name: pool.name,
      slug: pool.slug,
      kind: pool.kind,
      status: pool.status,
      env_vars: pool.env_vars,
      metadata: pool.metadata,
      items:
        Enum.map(
          (Ecto.assoc_loaded?(pool.items) && pool.items) || [],
          &credential_pool_item_json/1
        )
    }
  end

  defp credential_pool_item_json(item) do
    %{
      id: item.id,
      credential_pool_id: item.credential_pool_id,
      label: item.label,
      source: item.source,
      env_var: item.env_var,
      status: item.status,
      priority: item.priority,
      request_count: item.request_count,
      failure_count: item.failure_count,
      cooldown_until: item.cooldown_until,
      last_used_at: item.last_used_at,
      last_error: item.last_error,
      metadata: item.metadata
    }
  end

  defp assoc_json(parent, assoc, mapper) do
    value = Map.get(parent, assoc)

    if Ecto.assoc_loaded?(value) and value do
      mapper.(value)
    end
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
