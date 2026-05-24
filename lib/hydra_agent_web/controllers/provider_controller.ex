defmodule HydraAgentWeb.ProviderController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Providers, Runtime}

  def index(conn, %{"workspace_id" => workspace_id}) do
    providers = Runtime.list_providers(workspace_id)
    json(conn, %{data: Enum.map(providers, &provider_json/1)})
  end

  def show(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)
    json(conn, %{data: provider_json(provider)})
  end

  def create(conn, params) do
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

  def health(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)

    case Providers.health(provider) do
      :ok ->
        json(conn, %{data: %{status: "ok", provider: provider_json(provider)}})

      {:error, error} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{data: %{status: "error", provider: provider_json(provider), error: error}})
    end
  end

  def models(conn, %{"id" => id}) do
    provider = Runtime.get_provider!(id)

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
      enabled: provider.enabled,
      metadata: provider.metadata
    }
  end

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
