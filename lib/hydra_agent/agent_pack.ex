defmodule HydraAgent.AgentPack do
  @moduledoc """
  Validation and import helpers for declarative agent packs.

  V1 accepts decoded JSON maps. YAML support should be added through a small
  parser adapter without changing this validation contract.
  """

  alias HydraAgent.Runtime.Autonomy
  alias HydraAgent.Tools.Registry

  @version 1
  @required ~w(agent_pack_version slug name role description model_route tools skills memory_scopes knowledge_scopes permissions autonomy approval_policy)
  @dangerous_side_effects ~w(workspace_write shell network browser mcp external_delivery plugin_install)

  def version, do: @version

  def load_json(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      validate(decoded)
    end
  end

  def validate(pack) when is_map(pack) do
    pack = stringify_keys(pack)

    []
    |> require_fields(pack)
    |> validate_version(pack)
    |> validate_role(pack)
    |> validate_list(pack, "tools")
    |> validate_known_tools(pack)
    |> validate_list(pack, "skills")
    |> validate_list(pack, "memory_scopes")
    |> validate_list(pack, "knowledge_scopes")
    |> validate_autonomy(pack)
    |> validate_permissions(pack)
    |> validate_approval_policy(pack)
    |> case do
      [] -> {:ok, normalize(pack)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_pack), do: {:error, ["agent pack must be a map"]}

  def to_agent_attrs(pack, workspace_id) do
    with {:ok, pack} <- validate(pack) do
      {:ok,
       %{
         workspace_id: workspace_id,
         slug: pack["slug"],
         name: pack["name"],
         role: pack["role"],
         description: pack["description"],
         system_prompt: pack["system_prompt"],
         model_route: pack["model_route"],
         capability_profile: %{
           "role" => pack["role"],
           "tools" => pack["tools"],
           "skills" => pack["skills"],
           "side_effect_classes" => pack["permissions"]["side_effect_classes"],
           "max_autonomy_level" => pack["autonomy"]["level"],
           "approval_policy" => pack["approval_policy"]
         },
         memory_scopes: pack["memory_scopes"],
         knowledge_scopes: pack["knowledge_scopes"]
       }}
    end
  end

  def from_agent(agent) do
    capability_profile = agent.capability_profile || %{}

    %{
      "agent_pack_version" => @version,
      "slug" => agent.slug,
      "name" => agent.name,
      "role" => agent.role,
      "description" => agent.description || "",
      "system_prompt" => agent.system_prompt || "",
      "model_route" => agent.model_route || %{},
      "tools" => capability_profile["tools"] || [],
      "skills" => capability_profile["skills"] || [],
      "memory_scopes" => agent.memory_scopes || [],
      "knowledge_scopes" => agent.knowledge_scopes || [],
      "permissions" => %{
        "side_effect_classes" => capability_profile["side_effect_classes"] || ["read_only"],
        "requires_approval" => get_in(capability_profile, ["approval_policy", "mode"]) != "never"
      },
      "autonomy" => %{
        "level" => capability_profile["max_autonomy_level"] || "recommend"
      },
      "approval_policy" =>
        capability_profile["approval_policy"] || %{"mode" => "required_for_sensitive"}
    }
  end

  def export_agent(agent) do
    agent
    |> from_agent()
    |> Jason.encode_to_iodata!(pretty: true)
  end

  defp require_fields(errors, pack) do
    missing = Enum.reject(@required, &Map.has_key?(pack, &1))

    case missing do
      [] -> errors
      fields -> ["missing required fields: #{Enum.join(fields, ", ")}" | errors]
    end
  end

  defp validate_version(errors, %{"agent_pack_version" => @version}), do: errors
  defp validate_version(errors, _pack), do: ["agent_pack_version must be 1" | errors]

  defp validate_role(errors, %{"role" => role}) do
    if role in Autonomy.roles(), do: errors, else: ["role is not supported" | errors]
  end

  defp validate_role(errors, _pack), do: ["role is not supported" | errors]

  defp validate_list(errors, pack, field) do
    cond do
      not is_list(pack[field]) ->
        ["#{field} must be a list" | errors]

      Enum.all?(pack[field], &is_binary/1) ->
        errors

      true ->
        ["#{field} must contain only strings" | errors]
    end
  end

  defp validate_known_tools(errors, %{"tools" => tools}) when is_list(tools) do
    unknown = tools -- Registry.names()

    if unknown == [],
      do: errors,
      else: ["tools contains unknown registered tools: #{Enum.join(unknown, ", ")}" | errors]
  end

  defp validate_known_tools(errors, _pack), do: errors

  defp validate_autonomy(errors, %{"autonomy" => autonomy}) when is_map(autonomy) do
    autonomy = stringify_keys(autonomy)
    level = autonomy["level"] || "recommend"

    if level in Autonomy.autonomy_levels() do
      errors
    else
      ["autonomy.level is not supported" | errors]
    end
  end

  defp validate_autonomy(errors, _pack), do: ["autonomy must be a map" | errors]

  defp validate_permissions(errors, %{"permissions" => permissions}) when is_map(permissions) do
    permissions = stringify_keys(permissions)
    classes = List.wrap(permissions["side_effect_classes"] || ["read_only"])
    unknown = classes -- Autonomy.side_effect_classes()
    dangerous = classes -- ["read_only"]
    approval_required? = permissions["requires_approval"] != false

    errors =
      if unknown == [] do
        errors
      else
        [
          "permissions.side_effect_classes contains unknown values: #{Enum.join(unknown, ", ")}"
          | errors
        ]
      end

    if Enum.any?(dangerous, &(&1 in @dangerous_side_effects)) and not approval_required? do
      ["dangerous side effects must require approval by default" | errors]
    else
      errors
    end
  end

  defp validate_permissions(errors, _pack), do: ["permissions must be a map" | errors]

  defp validate_approval_policy(errors, %{"approval_policy" => policy}) when is_map(policy) do
    policy = stringify_keys(policy)
    mode = policy["mode"] || "required_for_sensitive"

    if mode in ~w(required_for_sensitive always never) do
      errors
    else
      ["approval_policy.mode is not supported" | errors]
    end
  end

  defp validate_approval_policy(errors, _pack), do: ["approval_policy must be a map" | errors]

  defp normalize(pack) do
    permissions =
      pack
      |> Map.get("permissions", %{})
      |> stringify_keys()
      |> Map.put_new("side_effect_classes", ["read_only"])
      |> Map.put_new("requires_approval", true)

    pack
    |> Map.put("permissions", permissions)
    |> Map.update!("autonomy", &stringify_keys/1)
    |> Map.update!("approval_policy", &stringify_keys/1)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
