defmodule HydraAgent.Providers do
  @moduledoc """
  Provider facade for chat, embeddings, model discovery, and health checks.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.{AgentProfile, CredentialPoolItem, ProviderConfig}

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
    |> preload([:credential_pool])
    |> Repo.all()
  end

  def get_config_by_name(workspace_id, name) when is_binary(name) do
    ProviderConfig
    |> where([provider], provider.name == ^name)
    |> where([provider], is_nil(provider.workspace_id) or provider.workspace_id == ^workspace_id)
    |> where([provider], provider.enabled == true)
    |> order_by([provider], desc: fragment("? IS NOT NULL", provider.workspace_id))
    |> limit(1)
    |> preload([:credential_pool])
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
    try_provider_credentials(provider, fn credential_provider ->
      with {:ok, adapter} <- adapter(credential_provider) do
        adapter.chat(credential_provider, normalize_request(request))
      end
    end)
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
    try_provider_credentials(provider, fn credential_provider ->
      with {:ok, adapter} <- adapter(credential_provider) do
        adapter.stream_chat(credential_provider, normalize_request(request), callback)
      end
    end)
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
    try_provider_credentials(provider, fn credential_provider ->
      with {:ok, adapter} <- adapter(credential_provider) do
        adapter.embed(credential_provider, normalize_request(request))
      end
    end)
  end

  def models(%ProviderConfig{} = provider) do
    try_provider_credentials(provider, fn credential_provider ->
      with {:ok, adapter} <- adapter(credential_provider) do
        adapter.models(credential_provider)
      end
    end)
  end

  def health(%ProviderConfig{} = provider) do
    try_provider_credentials(provider, fn credential_provider ->
      with {:ok, adapter} <- adapter(credential_provider) do
        adapter.health(credential_provider)
      end
    end)
  end

  defp try_provider_credentials(%ProviderConfig{} = provider, fun) when is_function(fun, 1) do
    case credential_variants(provider) do
      [] -> fun.(provider)
      variants -> try_credential_variants(variants, fun, nil)
    end
  end

  defp credential_variants(
         %ProviderConfig{credential_pool: %Ecto.Association.NotLoaded{}} = provider
       ) do
    provider
    |> Repo.preload(credential_pool: [:items])
    |> credential_variants()
  end

  defp credential_variants(%ProviderConfig{credential_pool: nil}), do: []

  defp credential_variants(%ProviderConfig{credential_pool: pool} = provider) do
    pool
    |> Runtime.list_credential_pool_items()
    |> Enum.filter(&eligible_credential_item?/1)
    |> Enum.map(fn item ->
      {%{provider | api_key_env: item.env_var}, item}
    end)
  end

  defp eligible_credential_item?(%CredentialPoolItem{} = item) do
    item.status == "active" and
      (is_nil(item.cooldown_until) or DateTime.compare(item.cooldown_until, now()) != :gt)
  end

  defp try_credential_variants([], _fun, last_error),
    do: {:error, last_error || %{"reason" => "no_active_credential"}}

  defp try_credential_variants([{provider, item} | rest], fun, _last_error) do
    Runtime.mark_credential_pool_item_used(item)

    case fun.(provider) do
      {:ok, response} ->
        {:ok,
         Map.update(response, "route", credential_route(provider, item), fn route ->
           Map.merge(route, credential_route(provider, item))
         end)}

      {:error, error} ->
        Runtime.mark_credential_pool_item_failed(item, error)
        try_credential_variants(rest, fun, error)
    end
  end

  defp credential_route(provider, item) do
    %{
      "credential_pool_id" => provider.credential_pool_id,
      "credential_pool_item_id" => item.id,
      "api_key_env" => item.env_var
    }
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
