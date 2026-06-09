defmodule HydraAgent.AgentPack do
  @moduledoc """
  Validation and import helpers for declarative agent packs.

  V1 accepts decoded JSON maps. YAML support should be added through a small
  parser adapter without changing this validation contract.
  """

  alias HydraAgent.Runtime.Autonomy
  alias HydraAgent.Tools.Bundles
  alias HydraAgent.Tools.Registry

  @version 1
  @required ~w(agent_pack_version slug name role description model_route tools skills memory_scopes knowledge_scopes permissions autonomy approval_policy)
  @dangerous_side_effects ~w(workspace_write shell network browser mcp external_delivery plugin_install)
  @capability_metadata_fields ~w(connector_requirements automation_recipes room_defaults task_pack content_channels delivery_targets)

  def version, do: @version

  def json_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://hydra-agent.local/schemas/agent-pack-v1.json",
      "title" => "Hydra Agent Pack",
      "type" => "object",
      "additionalProperties" => true,
      "required" => @required,
      "properties" => %{
        "agent_pack_version" => %{"const" => @version},
        "slug" => %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9-]*$"},
        "name" => %{"type" => "string", "minLength" => 1},
        "role" => %{"type" => "string", "enum" => Autonomy.roles()},
        "description" => %{"type" => "string"},
        "system_prompt" => %{"type" => "string"},
        "model_route" => %{"type" => "object"},
        "tools" => string_enum_array(Registry.names()),
        "tool_bundles" => string_enum_array(Bundles.names()),
        "connector_requirements" => string_array(),
        "automation_recipes" => string_array(),
        "room_defaults" => %{"type" => "object"},
        "task_pack" => %{"type" => "string"},
        "content_channels" => string_array(),
        "delivery_targets" => string_array(),
        "skills" => string_array(),
        "memory_scopes" => string_array(),
        "knowledge_scopes" => string_array(),
        "permissions" => %{
          "type" => "object",
          "required" => ["side_effect_classes", "requires_approval"],
          "properties" => %{
            "side_effect_classes" => string_enum_array(Autonomy.side_effect_classes()),
            "requires_approval" => %{"type" => "boolean"}
          }
        },
        "autonomy" => %{
          "type" => "object",
          "required" => ["level"],
          "properties" => %{
            "level" => %{"type" => "string", "enum" => Autonomy.autonomy_levels()}
          }
        },
        "approval_policy" => %{
          "type" => "object",
          "required" => ["mode"],
          "properties" => %{
            "mode" => %{"type" => "string", "enum" => ~w(required_for_sensitive always never)}
          }
        }
      }
    }
  end

  def load_json(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      validate(decoded)
    end
  end

  def builtin_packs(pattern \\ "agent_packs/*.agent.json") do
    pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      case load_json(path) do
        {:ok, pack} ->
          %{"path" => path, "status" => "valid", "pack" => pack}

        {:error, errors} ->
          %{"path" => path, "status" => "invalid", "errors" => builtin_error_messages(errors)}
      end
    end)
  end

  def valid_builtin_packs(pattern \\ "agent_packs/*.agent.json") do
    pattern
    |> builtin_packs()
    |> Enum.filter(&(&1["status"] == "valid"))
    |> Enum.map(& &1["pack"])
  end

  def validate(pack) when is_map(pack) do
    case validate_details(pack) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, details} -> {:error, error_messages(details)}
    end
  end

  def validate(_pack), do: {:error, ["agent pack must be a map"]}

  def validate_details(pack, opts \\ [])

  def validate_details(pack, opts) when is_map(pack) do
    pack = stringify_keys(pack)
    workspace_id = Keyword.get(opts, :workspace_id)

    []
    |> require_field_details(pack)
    |> validate_version_details(pack)
    |> validate_role_details(pack)
    |> validate_list_details(pack, "tools")
    |> validate_optional_list_details(pack, "tool_bundles")
    |> validate_known_tools_details(pack, workspace_id)
    |> validate_known_tool_bundles_details(pack, workspace_id)
    |> validate_list_details(pack, "skills")
    |> validate_list_details(pack, "memory_scopes")
    |> validate_list_details(pack, "knowledge_scopes")
    |> validate_autonomy_details(pack)
    |> validate_permissions_details(pack)
    |> validate_bundle_permissions_details(pack, workspace_id)
    |> validate_approval_policy_details(pack)
    |> case do
      [] -> {:ok, normalize(pack, workspace_id)}
      details -> {:error, Enum.reverse(details)}
    end
  end

  def validate_details(_pack, _opts) do
    {:error, [validation_error("agent_pack", "invalid_type", "agent pack must be a map")]}
  end

  def error_messages(details) when is_list(details), do: Enum.map(details, & &1["message"])

  def to_agent_attrs(pack, workspace_id) do
    with {:ok, pack} <- validate(pack) do
      capability_profile =
        %{
          "role" => pack["role"],
          "tools" => pack["tools"],
          "tool_bundles" => pack["tool_bundles"] || [],
          "skills" => pack["skills"],
          "side_effect_classes" => pack["permissions"]["side_effect_classes"],
          "max_autonomy_level" => pack["autonomy"]["level"],
          "approval_policy" => pack["approval_policy"]
        }
        |> Map.merge(pack_capability_metadata(pack))

      {:ok,
       %{
         workspace_id: workspace_id,
         slug: pack["slug"],
         name: pack["name"],
         role: pack["role"],
         description: pack["description"],
         system_prompt: pack["system_prompt"],
         model_route: pack["model_route"],
         capability_profile: capability_profile,
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
      "tool_bundles" => capability_profile["tool_bundles"] || [],
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
    |> Map.merge(pack_capability_metadata(capability_profile))
  end

  def export_agent(agent) do
    agent
    |> from_agent()
    |> Jason.encode_to_iodata!(pretty: true)
  end

  defp require_field_details(errors, pack) do
    missing = Enum.reject(@required, &Map.has_key?(pack, &1))

    case missing do
      [] ->
        errors

      fields ->
        [
          validation_error(
            "agent_pack",
            "missing_required_fields",
            "missing required fields: #{Enum.join(fields, ", ")}",
            %{"fields" => fields}
          )
          | errors
        ]
    end
  end

  defp validate_version_details(errors, %{"agent_pack_version" => @version}), do: errors

  defp validate_version_details(errors, _pack) do
    [
      validation_error(
        "agent_pack_version",
        "unsupported_version",
        "agent_pack_version must be 1",
        %{"supported_version" => @version}
      )
      | errors
    ]
  end

  defp validate_role_details(errors, %{"role" => role}) do
    if role in Autonomy.roles() do
      errors
    else
      [
        validation_error("role", "unsupported_role", "role is not supported", %{
          "allowed" => Autonomy.roles()
        })
        | errors
      ]
    end
  end

  defp validate_role_details(errors, _pack) do
    [validation_error("role", "unsupported_role", "role is not supported") | errors]
  end

  defp validate_list_details(errors, pack, field) do
    cond do
      not is_list(pack[field]) ->
        [validation_error(field, "not_a_list", "#{field} must be a list") | errors]

      Enum.all?(pack[field], &is_binary/1) ->
        errors

      true ->
        [
          validation_error(field, "non_string_items", "#{field} must contain only strings")
          | errors
        ]
    end
  end

  defp validate_optional_list_details(errors, pack, field) do
    if Map.has_key?(pack, field) do
      validate_list_details(errors, pack, field)
    else
      errors
    end
  end

  defp validate_known_tools_details(errors, %{"tools" => tools}, workspace_id)
       when is_list(tools) do
    allowed = if workspace_id, do: Registry.names(workspace_id), else: Registry.names()
    unknown = tools -- allowed

    if unknown == [],
      do: errors,
      else: [
        validation_error(
          "tools",
          "unknown_registered_tools",
          "tools contains unknown registered tools: #{Enum.join(unknown, ", ")}",
          %{"unknown" => unknown}
        )
        | errors
      ]
  end

  defp validate_known_tools_details(errors, _pack, _workspace_id), do: errors

  defp validate_known_tool_bundles_details(errors, %{"tool_bundles" => bundles}, workspace_id)
       when is_list(bundles) do
    allowed = if workspace_id, do: Bundles.names(workspace_id), else: Bundles.names()
    unknown = bundles -- allowed

    if unknown == [],
      do: errors,
      else: [
        validation_error(
          "tool_bundles",
          "unknown_tool_bundles",
          "tool_bundles contains unknown bundles: #{Enum.join(unknown, ", ")}",
          %{"unknown" => unknown}
        )
        | errors
      ]
  end

  defp validate_known_tool_bundles_details(errors, _pack, _workspace_id), do: errors

  defp validate_autonomy_details(errors, %{"autonomy" => autonomy}) when is_map(autonomy) do
    autonomy = stringify_keys(autonomy)
    level = autonomy["level"] || "recommend"

    if level in Autonomy.autonomy_levels() do
      errors
    else
      [
        validation_error(
          "autonomy.level",
          "unsupported_autonomy_level",
          "autonomy.level is not supported",
          %{"allowed" => Autonomy.autonomy_levels()}
        )
        | errors
      ]
    end
  end

  defp validate_autonomy_details(errors, _pack) do
    [validation_error("autonomy", "not_a_map", "autonomy must be a map") | errors]
  end

  defp validate_permissions_details(errors, %{"permissions" => permissions})
       when is_map(permissions) do
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
          validation_error(
            "permissions.side_effect_classes",
            "unknown_side_effect_classes",
            "permissions.side_effect_classes contains unknown values: #{Enum.join(unknown, ", ")}",
            %{"unknown" => unknown}
          )
          | errors
        ]
      end

    if Enum.any?(dangerous, &(&1 in @dangerous_side_effects)) and not approval_required? do
      [
        validation_error(
          "permissions.requires_approval",
          "dangerous_side_effects_without_approval",
          "dangerous side effects must require approval by default",
          %{"side_effect_classes" => dangerous}
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_permissions_details(errors, _pack) do
    [validation_error("permissions", "not_a_map", "permissions must be a map") | errors]
  end

  defp validate_bundle_permissions_details(
         errors,
         %{"permissions" => permissions} = pack,
         workspace_id
       )
       when is_map(permissions) do
    permissions = stringify_keys(permissions)
    bundles = List.wrap(pack["tool_bundles"] || [])

    case Bundles.expand(bundles, workspace_id) do
      {:ok, %{"requires_approval" => true}} ->
        if permissions["requires_approval"] == false do
          [
            validation_error(
              "permissions.requires_approval",
              "dangerous_tool_bundles_without_approval",
              "dangerous tool bundles must require approval by default",
              %{"tool_bundles" => bundles}
            )
            | errors
          ]
        else
          errors
        end

      _expanded_or_error ->
        errors
    end
  end

  defp validate_bundle_permissions_details(errors, _pack, _workspace_id), do: errors

  defp validate_approval_policy_details(errors, %{"approval_policy" => policy})
       when is_map(policy) do
    policy = stringify_keys(policy)
    mode = policy["mode"] || "required_for_sensitive"

    if mode in ~w(required_for_sensitive always never) do
      errors
    else
      [
        validation_error(
          "approval_policy.mode",
          "unsupported_approval_policy_mode",
          "approval_policy.mode is not supported",
          %{"allowed" => ~w(required_for_sensitive always never)}
        )
        | errors
      ]
    end
  end

  defp validate_approval_policy_details(errors, _pack) do
    [
      validation_error("approval_policy", "not_a_map", "approval_policy must be a map")
      | errors
    ]
  end

  defp normalize(pack, workspace_id) do
    permissions =
      pack
      |> Map.get("permissions", %{})
      |> stringify_keys()
      |> Map.put_new("side_effect_classes", ["read_only"])
      |> Map.put_new("requires_approval", true)

    pack
    |> Map.put("permissions", permissions)
    |> expand_tool_bundles(workspace_id)
    |> Map.update!("autonomy", &stringify_keys/1)
    |> Map.update!("approval_policy", &stringify_keys/1)
  end

  defp expand_tool_bundles(pack, workspace_id) do
    bundles = List.wrap(pack["tool_bundles"] || [])

    case Bundles.expand(bundles, workspace_id) do
      {:ok,
       %{
         "allowed_tools" => tools,
         "side_effect_classes" => side_effect_classes,
         "tool_bundles" => tool_bundles
       }} ->
        permissions =
          pack["permissions"]
          |> Map.update!("side_effect_classes", &Enum.uniq(List.wrap(&1) ++ side_effect_classes))

        pack
        |> Map.put("tool_bundles", tool_bundles)
        |> Map.put("tools", Enum.uniq(List.wrap(pack["tools"]) ++ tools))
        |> Map.put("permissions", permissions)

      {:error, _unknown} ->
        pack
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp pack_capability_metadata(pack) do
    Enum.reduce(@capability_metadata_fields, %{}, fn field, metadata ->
      if Map.has_key?(pack, field) do
        Map.put(metadata, field, pack[field])
      else
        metadata
      end
    end)
  end

  defp builtin_error_messages(errors) when is_list(errors), do: Enum.map(errors, &to_string/1)

  defp builtin_error_messages(%{__exception__: true} = error), do: [Exception.message(error)]

  defp builtin_error_messages(error), do: [inspect(error)]

  defp validation_error(field, code, message, metadata \\ %{}) do
    %{
      "field" => field,
      "code" => code,
      "message" => message,
      "metadata" => metadata
    }
  end

  defp string_array do
    %{"type" => "array", "items" => %{"type" => "string"}, "default" => []}
  end

  defp string_enum_array(values) do
    %{"type" => "array", "items" => %{"type" => "string", "enum" => values}, "default" => []}
  end
end
