defmodule HydraAgent.Runtime.ToolBundlePolicyTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.Authorizer

  test "tool policy creation expands bundles into explicit grants" do
    workspace = workspace_fixture()

    assert {:ok, policy} =
             Runtime.create_tool_policy(%{
               workspace_id: workspace.id,
               tool_bundles: ["files_write"]
             })

    assert policy.allowed_tools == ["file_list", "file_read", "file_write"]
    assert "read_only" in policy.side_effect_classes
    assert "workspace_write" in policy.side_effect_classes
    assert policy.requires_approval
    assert policy.metadata["tool_bundles"] == ["files_write"]
  end

  test "unknown bundles fail policy creation" do
    workspace = workspace_fixture()

    assert {:error, changeset} =
             Runtime.create_tool_policy(%{
               workspace_id: workspace.id,
               tool_bundles: ["missing_bundle"]
             })

    assert {"contains unknown tool bundles: missing_bundle", _meta} = changeset.errors[:metadata]
  end

  test "bundle policy does not bypass agent capabilities" do
    workspace = workspace_fixture()

    agent =
      agent_fixture(workspace, %{
        capability_profile: %{
          "tools" => ["file_read"],
          "side_effect_classes" => ["read_only"],
          "approval_policy" => %{"mode" => "required_for_sensitive"}
        }
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        tool_bundles: ["files_write"]
      })

    assert {:blocked, %{"reason" => "tool_not_in_agent_capabilities"}} =
             Authorizer.authorize(agent, "file_write",
               autonomy_level: "execute_with_approval",
               input: %{"path" => "README.md", "content" => "x"}
             )
  end

  test "network bundles still require explicit host allowlists" do
    workspace = workspace_fixture()

    agent =
      agent_fixture(workspace, %{
        capability_profile: %{
          "tools" => ["http_fetch", "source_ingest", "artifact_record"],
          "side_effect_classes" => ["read_only", "network", "workspace_write"],
          "approval_policy" => %{"mode" => "required_for_sensitive"}
        }
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        tool_bundles: ["web_research"],
        network_allowlist: []
      })

    assert {:blocked, %{"reason" => "network_host_not_allowed"}} =
             Authorizer.authorize(agent, "http_fetch",
               autonomy_level: "execute_with_approval",
               input: %{"url" => "https://example.com"}
             )
  end

  test "shell policies require explicit environment allowlists" do
    workspace = workspace_fixture()

    agent =
      agent_fixture(workspace, %{
        capability_profile: %{
          "tools" => ["shell_command"],
          "side_effect_classes" => ["shell"],
          "approval_policy" => %{"mode" => "never"}
        }
      })

    assert {:error, changeset} =
             Runtime.create_tool_policy(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               allowed_tools: ["shell_command"],
               side_effect_classes: ["shell"],
               shell_allowlist: ["sh -c"],
               shell_env_allowlist: ["HYDRA_ALLOWED_FLAG"],
               requires_approval: false
             })

    assert {"must be true for dangerous side effects", _meta} =
             changeset.errors[:requires_approval]

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        allowed_tools: ["shell_command"],
        side_effect_classes: ["shell"],
        shell_allowlist: ["sh -c"],
        shell_env_allowlist: ["HYDRA_ALLOWED_FLAG"]
      })

    assert {:approval_required,
            %{"metadata" => %{"shell_env_allowlist" => ["HYDRA_ALLOWED_FLAG"]}}} =
             Authorizer.authorize(agent, "shell_command",
               autonomy_level: "fully_automatic",
               input: %{
                 "command" => ["sh", "-c", "printf ok"],
                 "env" => %{"HYDRA_ALLOWED_FLAG" => "1"}
               }
             )

    assert {:blocked, %{"reason" => "shell_env_not_allowed"}} =
             Authorizer.authorize(agent, "shell_command",
               autonomy_level: "fully_automatic",
               input: %{
                 "command" => ["sh", "-c", "printf ok"],
                 "env" => %{"HYDRA_BLOCKED_FLAG" => "1"}
               }
             )
  end

  test "mcp authorization checks server state and tool filters" do
    workspace = workspace_fixture()

    agent =
      agent_fixture(workspace, %{
        capability_profile: %{
          "tools" => ["mcp_call"],
          "side_effect_classes" => ["mcp"],
          "approval_policy" => %{"mode" => "required_for_sensitive"}
        }
      })

    {:ok, server} =
      HydraAgent.MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-policy",
        status: "active",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        include_tools: ["search_docs"]
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        tool_bundles: ["mcp"]
      })

    assert {:approval_required, %{"reason" => "approval_required"}} =
             Authorizer.authorize(agent, "mcp_call",
               autonomy_level: "execute_with_approval",
               input: %{"server_id" => server.id, "tool_name" => "search_docs"}
             )

    assert {:blocked, %{"reason" => "mcp_tool_not_included"}} =
             Authorizer.authorize(agent, "mcp_call",
               autonomy_level: "execute_with_approval",
               input: %{"server_id" => server.id, "tool_name" => "write_docs"}
             )
  end
end
