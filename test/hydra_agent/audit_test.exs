defmodule HydraAgent.AuditTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Audit, MCP, Runtime}

  test "exports tool bundles, policy bundle grants, and MCP server refs" do
    workspace = workspace_fixture()

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        tool_bundles: ["files_read"],
        filesystem_allowlist: ["lib"],
        shell_env_allowlist: ["HYDRA_TEST_FLAG"],
        requires_approval: false
      })

    {:ok, _server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-audit",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"],
        include_tools: ["search_docs"]
      })

    export = Audit.export_workspace(workspace.id)

    assert Enum.any?(export["tool_bundles"], &(&1.name == "files_read"))

    assert [%{"tool_bundles" => ["files_read"], "shell_env_allowlist" => ["HYDRA_TEST_FLAG"]}] =
             export["tool_policies"]

    assert [
             %{
               "slug" => "docs-mcp-audit",
               "env_refs" => ["MCP_DOCS_TOKEN"],
               "include_tools" => ["search_docs"]
             }
           ] = export["mcp_servers"]
  end
end
