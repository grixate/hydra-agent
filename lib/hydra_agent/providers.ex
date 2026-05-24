defmodule HydraAgent.Providers do
  @moduledoc """
  Provider facade for chat, embeddings, model discovery, and health checks.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime.{AgentProfile, ProviderConfig}

  @adapters %{
    "mock" => HydraAgent.Providers.Mock,
    "openai_compatible" => HydraAgent.Providers.OpenAICompatible,
    "anthropic" => HydraAgent.Providers.Anthropic,
    "ollama" => HydraAgent.Providers.Ollama
  }

  def adapters, do: @adapters

  def list_configs(workspace_id) do
    ProviderConfig
    |> where([provider], is_nil(provider.workspace_id) or provider.workspace_id == ^workspace_id)
    |> where([provider], provider.enabled == true)
    |> order_by([provider], asc: provider.name)
    |> Repo.all()
  end

  def get_config_by_name(workspace_id, name) when is_binary(name) do
    ProviderConfig
    |> where([provider], provider.name == ^name)
    |> where([provider], is_nil(provider.workspace_id) or provider.workspace_id == ^workspace_id)
    |> where([provider], provider.enabled == true)
    |> order_by([provider], desc: fragment("? IS NOT NULL", provider.workspace_id))
    |> limit(1)
    |> Repo.one()
  end

  def route_for_agent(%AgentProfile{} = agent) do
    case route_configs_for_agent(agent) do
      [] -> {:error, %{"reason" => "no_enabled_provider", "route" => agent.model_route || %{}}}
      [provider | _providers] -> {:ok, provider}
    end
  end

  def route_configs_for_agent(%AgentProfile{} = agent) do
    agent
    |> route_provider_names()
    |> Enum.map(&get_config_by_name(agent.workspace_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  def chat(%ProviderConfig{} = provider, request) do
    with {:ok, adapter} <- adapter(provider) do
      adapter.chat(provider, normalize_request(request))
    end
  end

  def chat(%AgentProfile{} = agent, request) do
    providers = route_configs_for_agent(agent)

    case providers do
      [] ->
        {:error, %{"reason" => "no_enabled_provider", "route" => agent.model_route || %{}}}

      providers ->
        try_chat_route(providers, request, [])
    end
  end

  def stream_chat(%ProviderConfig{} = provider, request, callback)
      when is_function(callback, 1) do
    with {:ok, adapter} <- adapter(provider) do
      adapter.stream_chat(provider, normalize_request(request), callback)
    end
  end

  def stream_chat(%AgentProfile{} = agent, request, callback) when is_function(callback, 1) do
    providers = route_configs_for_agent(agent)

    case providers do
      [] ->
        {:error, %{"reason" => "no_enabled_provider", "route" => agent.model_route || %{}}}

      providers ->
        try_stream_chat_route(providers, request, callback, [])
    end
  end

  def embed(%ProviderConfig{} = provider, request) do
    with {:ok, adapter} <- adapter(provider) do
      adapter.embed(provider, normalize_request(request))
    end
  end

  def models(%ProviderConfig{} = provider) do
    with {:ok, adapter} <- adapter(provider) do
      adapter.models(provider)
    end
  end

  def health(%ProviderConfig{} = provider) do
    with {:ok, adapter} <- adapter(provider) do
      adapter.health(provider)
    end
  end

  defp adapter(%ProviderConfig{} = provider) do
    case Map.fetch(@adapters, provider.kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, %{"reason" => "unsupported_provider_kind", "kind" => provider.kind}}
    end
  end

  defp route_provider_names(%AgentProfile{} = agent) do
    route = agent.model_route || %{}

    [route["default_provider"] | List.wrap(route["fallback_providers"] || [])]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_request(request) when is_map(request) do
    Map.new(request, fn {key, value} -> {to_string(key), value} end)
  end

  defp try_chat_route([provider | rest], request, attempts) do
    case chat(provider, request) do
      {:ok, response} ->
        {:ok,
         Map.put(response, "route", %{
           "selected_provider" => provider.name,
           "attempts" => Enum.reverse([attempt(provider, "ok") | attempts])
         })}

      {:error, error} ->
        try_chat_route(rest, request, [attempt(provider, "error", error) | attempts])
    end
  end

  defp try_chat_route([], _request, attempts) do
    {:error, %{"reason" => "all_providers_failed", "attempts" => Enum.reverse(attempts)}}
  end

  defp try_stream_chat_route([provider | rest], request, callback, attempts) do
    case stream_chat(provider, request, callback) do
      {:ok, response} ->
        {:ok,
         Map.put(response, "route", %{
           "selected_provider" => provider.name,
           "attempts" => Enum.reverse([attempt(provider, "ok") | attempts]),
           "streamed" => true
         })}

      {:error, error} ->
        try_stream_chat_route(rest, request, callback, [
          attempt(provider, "error", error) | attempts
        ])
    end
  end

  defp try_stream_chat_route([], _request, _callback, attempts) do
    {:error, %{"reason" => "all_providers_failed", "attempts" => Enum.reverse(attempts)}}
  end

  defp attempt(provider, status, error \\ nil) do
    %{
      "provider" => provider.name,
      "kind" => provider.kind,
      "model" => provider.model,
      "status" => status,
      "error" => error
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
