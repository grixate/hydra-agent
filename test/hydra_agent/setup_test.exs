defmodule HydraAgent.SetupTest do
  use HydraAgent.DataCase

  alias HydraAgent.{Knowledge, Runtime, Setup, Skills}

  test "bootstraps a usable first workspace" do
    assert {:ok, result} =
             Setup.bootstrap(%{
               "workspace_name" => "Ops",
               "workspace_slug" => "ops",
               "provider_kind" => "mock",
               "provider_model" => "mock-chat",
               "seed_skills" => "true",
               "install_starter_agents" => "true"
             })

    assert result.workspace.slug == "ops"
    assert Enum.map(result.providers, & &1.name) == ["strong", "fast"]
    assert length(result.agents) == length(HydraAgent.AgentPack.valid_builtin_packs())
    assert length(result.policies) == length(result.agents)
    assert Knowledge.list_type_definitions(result.workspace.id) != []
    assert Skills.list_skills(result.workspace.id) != []

    assert Enum.all?(Runtime.list_tool_policies(result.workspace.id), fn policy ->
             policy.requires_approval == true or policy.side_effect_classes == ["read_only"]
           end)
  end

  test "can create only workspace and graph defaults" do
    assert {:ok, result} =
             Setup.bootstrap(%{
               "workspace_name" => "Quiet",
               "provider_kind" => "none",
               "seed_skills" => "false",
               "install_starter_agents" => "false"
             })

    assert result.workspace.slug == "quiet"
    assert result.providers == []
    assert result.agents == []
    assert Knowledge.list_type_definitions(result.workspace.id) != []
  end
end
