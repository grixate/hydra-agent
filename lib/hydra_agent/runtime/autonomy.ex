defmodule HydraAgent.Runtime.Autonomy do
  @moduledoc """
  Shared vocabulary for roles, autonomy, and side-effect classes.
  """

  @roles ~w(supervisor planner researcher builder reviewer operator memory_curator security_reviewer)
  @autonomy_levels ~w(observe recommend execute_with_review execute_with_approval fully_automatic)
  @side_effect_classes ~w(read_only workspace_write shell network browser mcp external_delivery plugin_install)

  def roles, do: @roles
  def autonomy_levels, do: @autonomy_levels
  def side_effect_classes, do: @side_effect_classes

  def default_capability_profile(role) when is_binary(role) do
    base = %{
      "role" => role,
      "tools" => ["knowledge_search", "knowledge_read", "noop"],
      "side_effect_classes" => ["read_only"],
      "max_autonomy_level" => "recommend"
    }

    case role do
      "supervisor" ->
        Map.merge(base, %{
          "tools" => ["knowledge_search", "knowledge_read", "noop", "run_create", "run_delegate"],
          "max_autonomy_level" => "execute_with_review"
        })

      "builder" ->
        Map.merge(base, %{
          "tools" => [
            "knowledge_search",
            "knowledge_read",
            "knowledge_write",
            "relationship_create",
            "file_list",
            "file_read",
            "file_write",
            "shell_command",
            "noop"
          ],
          "side_effect_classes" => ["read_only", "workspace_write", "shell"],
          "max_autonomy_level" => "execute_with_approval"
        })

      "researcher" ->
        Map.merge(base, %{
          "tools" => [
            "knowledge_search",
            "knowledge_read",
            "knowledge_write",
            "relationship_create",
            "http_fetch",
            "noop"
          ],
          "side_effect_classes" => ["read_only", "workspace_write", "network"],
          "max_autonomy_level" => "execute_with_review"
        })

      "security_reviewer" ->
        Map.merge(base, %{
          "tools" => [
            "knowledge_search",
            "knowledge_read",
            "knowledge_write",
            "relationship_create",
            "file_list",
            "file_read",
            "shell_command",
            "noop"
          ],
          "side_effect_classes" => ["read_only", "workspace_write", "shell"],
          "max_autonomy_level" => "execute_with_review"
        })

      _ ->
        base
    end
  end

  def default_capability_profile(_role), do: default_capability_profile("operator")
end
