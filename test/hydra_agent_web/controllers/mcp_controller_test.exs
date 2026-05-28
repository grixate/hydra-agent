defmodule HydraAgentWeb.McpControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "creates and lists MCP servers", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mcp-api"})

    create_conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/mcp_servers", %{
        name: "Docs MCP",
        slug: "docs-mcp",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"],
        include_tools: ["search_docs"]
      })

    assert %{
             "data" => %{
               "id" => id,
               "status" => "inactive",
               "transport" => "http",
               "env_refs" => ["MCP_DOCS_TOKEN"],
               "include_tools" => ["search_docs"]
             }
           } = json_response(create_conn, 201)

    list_conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/mcp_servers")

    assert %{"data" => [%{"id" => ^id, "slug" => "docs-mcp"}]} = json_response(list_conn, 200)
  end

  test "rejects MCP servers with inline secret config", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mcp-api-reject"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/mcp_servers", %{
        name: "Bad MCP",
        slug: "bad-mcp",
        transport: "http",
        config: %{"url" => "https://mcp.example.com", "api_key" => "secret"}
      })

    assert %{"errors" => %{"config" => [message]}} = json_response(conn, 422)
    assert message =~ "must not contain inline secret-like keys"
  end
end
