defmodule HydraAgent.AgentBuilder do
  @moduledoc """
  Guided agent creation from a small set of product-level presets.
  """

  alias HydraAgent.{Repo, Runtime}
  alias HydraAgent.Tools.Bundles

  @presets %{
    "coordinator" => %{
      "role" => "planner",
      "description" => "Routes work to the right agents and summarizes decisions.",
      "tool_bundles" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "researcher" => %{
      "role" => "researcher",
      "description" => "Finds, summarizes, and records evidence.",
      "tool_bundles" => ["knowledge_read", "web_research"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "builder" => %{
      "role" => "builder",
      "description" => "Edits files and runs allowlisted project commands.",
      "tool_bundles" => ["files_write", "terminal"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "reviewer" => %{
      "role" => "reviewer",
      "description" => "Reviews runs, files, traces, and evidence.",
      "tool_bundles" => ["files_read", "knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "memory_curator" => %{
      "role" => "memory_curator",
      "description" => "Reviews and improves durable memory.",
      "tool_bundles" => ["knowledge_write"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "chief_of_staff" => %{
      "role" => "chief_of_staff",
      "description" => "Coordinates everyday tasks, briefings, reminders, and agent handoffs.",
      "tool_bundles" => ["knowledge_read", "web_research"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "inbox_assistant" => %{
      "role" => "inbox_assistant",
      "description" => "Triages messages, prepares replies, and escalates sends for approval.",
      "tool_bundles" => ["knowledge_read", "web_research"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "calendar_assistant" => %{
      "role" => "calendar_assistant",
      "description" => "Prepares meeting briefs and proposes calendar changes.",
      "tool_bundles" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "knowledge_curator" => %{
      "role" => "knowledge_curator",
      "description" => "Organizes notes, research, memory candidates, and second-brain updates.",
      "tool_bundles" => ["knowledge_write"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "content_producer" => %{
      "role" => "content_producer",
      "description" => "Turns research into content drafts without publishing automatically.",
      "tool_bundles" => ["knowledge_read", "web_research"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "social_drafter" => %{
      "role" => "social_drafter",
      "description" => "Drafts X, LinkedIn, and long-form social content for approval.",
      "tool_bundles" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    "browser_operator" => %{
      "role" => "browser_operator",
      "description" => "Uses policy-gated browser automation for research and extraction.",
      "tool_bundles" => ["knowledge_read", "browser"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    }
  }

  def presets, do: @presets

  def preview(workspace_id, attrs) do
    attrs = stringify_keys(attrs || %{})
    preset = Map.get(@presets, attrs["preset"] || "coordinator", @presets["coordinator"])
    name = present(attrs["name"]) || titleize(attrs["preset"] || "coordinator")
    slug = present(attrs["slug"]) || slugify(name)
    tool_bundles = list_value(attrs["tool_bundles"], preset["tool_bundles"])
    skills = list_value(attrs["skills"], [])
    bundle_attrs = expanded_bundles(tool_bundles)

    agent = %{
      "workspace_id" => workspace_id,
      "name" => name,
      "slug" => slug,
      "role" => present(attrs["role"]) || preset["role"],
      "description" => present(attrs["description"]) || preset["description"],
      "system_prompt" => present(attrs["system_prompt"]) || default_prompt(name, preset),
      "model_route" => model_route(attrs),
      "memory_scopes" => list_value(attrs["memory_scopes"], preset["memory_scopes"]),
      "knowledge_scopes" => list_value(attrs["knowledge_scopes"], preset["knowledge_scopes"]),
      "capability_profile" => %{
        "tools" => bundle_attrs["allowed_tools"],
        "tool_bundles" => tool_bundles,
        "skills" => skills,
        "side_effect_classes" => bundle_attrs["side_effect_classes"],
        "max_autonomy_level" => present(attrs["max_autonomy_level"]) || "recommend",
        "approval_policy" => %{
          "mode" => present(attrs["approval_mode"]) || "required_for_sensitive"
        }
      }
    }

    policy = %{
      "workspace_id" => workspace_id,
      "tool_bundles" => tool_bundles,
      "requires_approval" =>
        approval_required?(attrs["requires_approval"], bundle_attrs["requires_approval"]),
      "filesystem_allowlist" => list_value(attrs["filesystem_allowlist"], []),
      "network_allowlist" => list_value(attrs["network_allowlist"], []),
      "shell_allowlist" => list_value(attrs["shell_allowlist"], []),
      "shell_env_allowlist" => list_value(attrs["shell_env_allowlist"], []),
      "metadata" => %{
        "created_from" => "agent_builder",
        "preset" => attrs["preset"] || "coordinator"
      }
    }

    %{"agent" => agent, "policy" => policy}
  end

  def create(workspace_id, attrs) do
    preview = preview(workspace_id, attrs)

    case Runtime.create_agent(preview["agent"]) do
      {:ok, agent} ->
        policy_attrs = Map.put(preview["policy"], "agent_id", agent.id)

        case Runtime.create_tool_policy(policy_attrs) do
          {:ok, policy} ->
            {:ok, %{agent: agent, policy: policy, preview: preview}}

          {:error, error} ->
            Repo.delete(agent)
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp expanded_bundles([]),
    do: %{
      "allowed_tools" => [],
      "side_effect_classes" => ["read_only"],
      "requires_approval" => false
    }

  defp expanded_bundles(tool_bundles) do
    case Bundles.expand(tool_bundles) do
      {:ok, attrs} -> attrs
      {:error, _unknown} -> %{"allowed_tools" => [], "side_effect_classes" => ["read_only"]}
    end
  end

  defp model_route(attrs) do
    %{}
    |> maybe_put("default_provider", present(attrs["default_provider"]))
    |> maybe_put("default_model", present(attrs["default_model"]))
  end

  defp default_prompt(name, preset) do
    "You are #{name}. #{preset["description"]} Work inside Hydra policy and ask for approval before risky actions."
  end

  defp list_value(value, default) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      values -> values
    end
  end

  defp list_value(value, _default) when is_list(value), do: value
  defp list_value(_value, default), do: default

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_value), do: nil

  defp titleize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp approval_required?(_value, true), do: true
  defp approval_required?(nil, bundle_default), do: bundle_default
  defp approval_required?(false, _bundle_default), do: false
  defp approval_required?("false", _bundle_default), do: false
  defp approval_required?("0", _bundle_default), do: false
  defp approval_required?("off", _bundle_default), do: false
  defp approval_required?("no", _bundle_default), do: false
  defp approval_required?(_value, _bundle_default), do: true

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
