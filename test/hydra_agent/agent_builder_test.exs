defmodule HydraAgent.AgentBuilderTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{AgentBuilder, Runtime}

  test "previews a builder agent with explicit policy bundles" do
    workspace = workspace_fixture()

    preview =
      AgentBuilder.preview(workspace.id, %{
        preset: "builder",
        name: "Patch Builder",
        skills: "elixir, phoenix",
        default_provider: "mock"
      })

    assert preview["agent"]["slug"] == "patch-builder"
    assert preview["agent"]["role"] == "builder"
    assert "file_write" in preview["agent"]["capability_profile"]["tools"]
    assert preview["agent"]["capability_profile"]["skills"] == ["elixir", "phoenix"]
    assert preview["policy"]["tool_bundles"] == ["files_write", "terminal"]
    assert preview["policy"]["requires_approval"] == true
  end

  test "honors explicit no-approval only for safe bundles" do
    workspace = workspace_fixture()

    reviewer =
      AgentBuilder.preview(workspace.id, %{
        preset: "reviewer",
        name: "Safe Reviewer",
        requires_approval: "false"
      })

    builder =
      AgentBuilder.preview(workspace.id, %{
        preset: "builder",
        name: "Risky Builder",
        requires_approval: "false"
      })

    assert reviewer["policy"]["requires_approval"] == false
    assert builder["policy"]["requires_approval"] == true
  end

  test "includes daily OS agent presets" do
    presets = AgentBuilder.presets()

    assert presets["chief_of_staff"]["role"] == "chief_of_staff"
    assert presets["browser_operator"]["tool_bundles"] == ["knowledge_read", "browser"]
    assert presets["social_drafter"]["description"] =~ "Drafts"
  end

  test "creates an agent and matching policy from a preset" do
    workspace = workspace_fixture()

    assert {:ok, %{agent: agent, policy: policy}} =
             AgentBuilder.create(workspace.id, %{
               preset: "reviewer",
               name: "Review Lead",
               default_provider: "mock"
             })

    assert agent.slug == "review-lead"
    assert policy.agent_id == agent.id
    assert "file_read" in policy.allowed_tools

    [listed] = Runtime.list_agents(workspace.id)
    assert listed.id == agent.id
  end
end
