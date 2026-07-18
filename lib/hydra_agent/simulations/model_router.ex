defmodule HydraAgent.Simulations.ModelRouter do
  @moduledoc "Resolves role-based model selections without exposing provider credentials."

  alias HydraAgent.{Runtime, Secrets}
  alias HydraAgent.Simulations.ContentHash

  @roles ~w(build simulation report)

  @requirements %{
    "build" => ["structured_generation"],
    "simulation" => ["structured_generation"],
    "report" => ["structured_generation"]
  }

  def roles, do: @roles
  def capability_requirements, do: @requirements

  def build(workspace_id, mode, selection) do
    selection = normalize_selection(selection, mode)
    providers = Runtime.list_providers(workspace_id) |> Enum.filter(& &1.enabled)

    resolved =
      Map.new(@roles, fn role ->
        {role, resolve_role(role, selection[role], providers)}
      end)

    contract = %{
      "selection" => selection,
      "resolved_routes" => resolved,
      "capability_requirements" => @requirements
    }

    Map.put(contract, "content_hash", ContentHash.digest(contract))
  end

  def available_routes(workspace_id) do
    workspace_id
    |> Runtime.list_providers()
    |> Enum.filter(&(&1.enabled and provider_ready?(&1)))
    |> Enum.map(&public_provider/1)
    |> Enum.sort_by(&{not &1["local"], &1["name"], &1["id"]})
  end

  defp normalize_selection(selection, mode) do
    selection = stringify_map(selection)

    Map.new(@roles, fn role ->
      value =
        cond do
          role == "simulation" and mode == "quick" -> "none"
          selection[role] in [nil, ""] -> "automatic"
          true -> to_string(selection[role])
        end

      {role, value}
    end)
  end

  defp resolve_role(_role, "none", _providers) do
    %{
      "selection" => "none",
      "status" => "disabled",
      "provider" => nil,
      "model" => nil,
      "local" => true,
      "capabilities" => %{}
    }
  end

  defp resolve_role(role, "automatic", providers) do
    case Enum.find(sort_for_role(providers, role), &eligible?(&1, role)) do
      nil ->
        %{
          "selection" => "automatic",
          "status" => "unavailable",
          "provider" => nil,
          "model" => nil,
          "local" => false,
          "capabilities" => %{}
        }

      provider ->
        provider
        |> public_provider()
        |> Map.merge(%{"selection" => "automatic", "status" => "resolved"})
    end
  end

  defp resolve_role(role, selected, providers) do
    case Enum.find(providers, &(to_string(&1.id) == selected and eligible?(&1, role))) do
      nil ->
        %{
          "selection" => selected,
          "status" => "unavailable",
          "provider" => nil,
          "model" => nil,
          "local" => false,
          "capabilities" => %{}
        }

      provider ->
        provider
        |> public_provider()
        |> Map.merge(%{"selection" => selected, "status" => "resolved"})
    end
  end

  defp sort_for_role(providers, "simulation") do
    Enum.sort_by(providers, fn provider ->
      capabilities = capabilities(provider)
      {not capabilities["local_execution"], provider.kind == "mock", provider.id}
    end)
  end

  defp sort_for_role(providers, _role), do: Enum.sort_by(providers, & &1.id)

  defp eligible?(provider, role) do
    capabilities = capabilities(provider)
    provider_ready?(provider) and Enum.all?(@requirements[role], &(capabilities[&1] == true))
  end

  defp provider_ready?(provider) when provider.kind in ~w(mock ollama), do: true

  defp provider_ready?(%{credential_pool: nil, api_key_env: env}),
    do: match?({:ok, _secret}, Secrets.fetch_env(env))

  defp provider_ready?(%{credential_pool: pool}) do
    pool
    |> Runtime.list_credential_pool_items()
    |> Enum.any?(fn item ->
      item.status == "active" and
        (is_nil(item.cooldown_until) or
           DateTime.compare(item.cooldown_until, DateTime.utc_now()) != :gt) and
        match?({:ok, _secret}, Secrets.fetch_env(item.env_var))
    end)
  end

  defp public_provider(provider) do
    capabilities = capabilities(provider)

    %{
      "id" => to_string(provider.id),
      "name" => provider.name,
      "provider" => provider.kind,
      "model" => provider.model,
      "local" => capabilities["local_execution"] == true,
      "capabilities" => capabilities,
      "route_version" =>
        ContentHash.digest(%{
          "id" => provider.id,
          "kind" => provider.kind,
          "model" => provider.model,
          "capabilities" => capabilities,
          "updated_at" =>
            if(provider.updated_at, do: DateTime.to_iso8601(provider.updated_at), else: nil)
        })
    }
  end

  defp capabilities(provider) do
    configured =
      provider.metadata
      |> Kernel.||(%{})
      |> Map.get("capabilities", %{})
      |> stringify_map()

    defaults = %{
      "structured_generation" => provider.kind in ~w(mock ollama openai_compatible anthropic),
      "local_execution" => provider.kind in ~w(mock ollama),
      "long_context" => false,
      "deterministic_seed" => provider.kind in ~w(mock ollama),
      "vision" => false,
      "languages" => ["en", "ru"]
    }

    Map.merge(defaults, configured)
  end

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(_value), do: %{}
end
