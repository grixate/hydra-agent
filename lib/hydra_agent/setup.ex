defmodule HydraAgent.Setup do
  @moduledoc """
  First-run setup helpers for turning a fresh database into a usable workspace.
  """

  import Ecto.Query

  alias HydraAgent.{AgentPack, Knowledge, Providers, Repo, Runtime, Skills}
  alias HydraAgent.Runtime.{AgentProfile, ToolPolicy}

  @provider_names ["strong", "fast"]

  def first_run_required? do
    Runtime.list_workspaces() == []
  end

  def bootstrap(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, workspace} <- Runtime.create_workspace(workspace_attrs(attrs)),
         {:ok, providers} <- ensure_route_providers(workspace.id, attrs),
         {:ok, type_definitions} <- seed_type_definitions(workspace.id),
         {:ok, skills} <- maybe_seed_skills(workspace.id, attrs),
         {:ok, agent_results} <- maybe_install_starter_agents(workspace.id, attrs) do
      {:ok,
       %{
         workspace: workspace,
         providers: providers,
         type_definitions: type_definitions,
         skills: skills,
         agents: Enum.map(agent_results, & &1.agent),
         policies: Enum.map(agent_results, & &1.policy) |> Enum.reject(&is_nil/1)
       }}
    end
  end

  def default_attrs do
    %{
      "workspace_name" => "Ops",
      "workspace_slug" => "ops",
      "provider_kind" => "mock",
      "provider_model" => "mock-chat",
      "provider_base_url" => "",
      "provider_api_key_env" => "",
      "seed_skills" => "true",
      "install_starter_agents" => "true"
    }
  end

  def provider_options do
    [
      {"mock", "Mock provider"},
      {"openai_compatible", "OpenAI-compatible"},
      {"anthropic", "Anthropic"},
      {"ollama", "Ollama"},
      {"none", "Skip provider for now"}
    ]
  end

  def model_placeholder("mock"), do: "mock-chat"
  def model_placeholder("openai_compatible"), do: "gpt-4.1-mini"
  def model_placeholder("anthropic"), do: "claude-sonnet-4"
  def model_placeholder("ollama"), do: "llama3.1"
  def model_placeholder(_kind), do: "model-name"

  defp workspace_attrs(attrs) do
    name = present(attrs["workspace_name"]) || "Ops"
    slug = present(attrs["workspace_slug"]) || slugify(name)

    %{
      name: name,
      slug: slug,
      description:
        present(attrs["workspace_description"]) ||
          "Primary Hydra runtime workspace."
    }
  end

  defp ensure_route_providers(workspace_id, attrs) do
    kind = attrs["provider_kind"] || "mock"

    if kind in ["", "none"] do
      {:ok, []}
    else
      Enum.reduce_while(@provider_names, {:ok, []}, fn name, {:ok, providers} ->
        case ensure_provider(workspace_id, name, kind, attrs) do
          {:ok, provider} -> {:cont, {:ok, [provider | providers]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, providers} -> {:ok, Enum.reverse(providers)}
        error -> error
      end
    end
  end

  defp ensure_provider(workspace_id, name, kind, attrs) do
    case Providers.get_config_by_name(workspace_id, name) do
      nil ->
        Runtime.create_provider(provider_attrs(workspace_id, name, kind, attrs))

      provider ->
        {:ok, provider}
    end
  end

  defp provider_attrs(workspace_id, name, kind, attrs) do
    %{
      workspace_id: workspace_id,
      name: name,
      kind: kind,
      model: present(attrs["provider_model"]) || model_placeholder(kind),
      base_url: present(attrs["provider_base_url"]),
      api_key_env: provider_api_key_env(kind, attrs),
      enabled: true,
      metadata: %{"created_by" => "first_run_setup"}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_api_key_env(kind, attrs) when kind in ["mock", "ollama"],
    do: present(attrs["provider_api_key_env"])

  defp provider_api_key_env(_kind, attrs), do: present(attrs["provider_api_key_env"])

  defp seed_type_definitions(workspace_id) do
    Knowledge.seed_neutral_type_definitions(workspace_id) |> collect_results()
  end

  defp maybe_seed_skills(workspace_id, attrs) do
    if truthy?(attrs["seed_skills"]) do
      Skills.seed_standard_skill_pack(workspace_id)
    else
      {:ok, []}
    end
  end

  defp maybe_install_starter_agents(workspace_id, attrs) do
    if truthy?(attrs["install_starter_agents"]) do
      AgentPack.valid_builtin_packs()
      |> Enum.reduce_while({:ok, []}, fn pack, {:ok, results} ->
        case ensure_agent_and_policy(workspace_id, pack) do
          {:ok, result} -> {:cont, {:ok, [result | results]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  defp ensure_agent_and_policy(workspace_id, pack) do
    with {:ok, agent} <- ensure_agent(workspace_id, pack),
         {:ok, policy} <- ensure_policy(agent, pack) do
      {:ok, %{agent: agent, policy: policy, pack: pack}}
    end
  end

  defp ensure_agent(workspace_id, pack) do
    case Runtime.get_agent_by_slug(workspace_id, pack["slug"]) do
      nil ->
        with {:ok, attrs} <- AgentPack.to_agent_attrs(pack, workspace_id) do
          Runtime.create_agent(attrs)
        end

      %AgentProfile{} = agent ->
        {:ok, agent}
    end
  end

  defp ensure_policy(%AgentProfile{} = agent, pack) do
    case existing_agent_policy(agent) do
      nil ->
        Runtime.create_tool_policy(%{
          workspace_id: agent.workspace_id,
          agent_id: agent.id,
          scope: "agent",
          allowed_tools: pack["tools"] || [],
          side_effect_classes:
            get_in(pack, ["permissions", "side_effect_classes"]) || ["read_only"],
          requires_approval: get_in(pack, ["permissions", "requires_approval"]) != false,
          metadata: %{
            "tool_bundles" => pack["tool_bundles"] || [],
            "created_by" => "first_run_setup"
          }
        })

      %ToolPolicy{} = policy ->
        {:ok, policy}
    end
  end

  defp existing_agent_policy(%AgentProfile{} = agent) do
    ToolPolicy
    |> where(
      [policy],
      policy.workspace_id == ^agent.workspace_id and policy.agent_id == ^agent.id
    )
    |> order_by([policy], desc: policy.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp collect_results(results) do
    errors = Enum.filter(results, &match?({:error, _error}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, value} -> value end)}
    else
      {:error, Enum.map(errors, fn {:error, error} -> error end)}
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(value), do: value

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      slug -> slug
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
