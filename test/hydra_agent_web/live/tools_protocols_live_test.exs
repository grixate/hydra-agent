defmodule HydraAgentWeb.ToolsProtocolsLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.{Connectors, Gateways, MCP, Runtime}

  test "renders empty tools and protocols page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/tools")

    assert html =~ "Tools And Protocols"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/tools?workspace_id=not-an-id")

    assert html =~ "Tools And Protocols"
    assert render(view) =~ workspace.name
  end

  test "renders tools, bundles, policies, MCP servers, webhooks, and status summaries", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools"})
    agent = agent_fixture(workspace)

    {:ok, policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        tool_bundles: ["files_read"],
        requires_approval: false,
        network_allowlist: ["example.com"],
        shell_allowlist: ["mix test"],
        shell_env_allowlist: ["MIX_ENV"],
        filesystem_allowlist: ["lib"]
      })

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-tools",
        status: "active",
        transport: "http",
        trust_level: "sandboxed",
        health_status: "healthy",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"],
        include_tools: ["search_docs"],
        resource_access: true
      })

    {:ok, pool} =
      Runtime.create_credential_pool(%{
        workspace_id: workspace.id,
        name: "Provider Secrets",
        env_vars: ["OPENAI_API_KEY"]
      })

    {:ok, webhook} =
      Gateways.create_webhook(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Deploy Review",
        slug: "deploy-review-tools",
        target_type: "agent_chat",
        token_env: "HYDRA_WEBHOOK_TOKEN",
        last_error: %{"reason" => "timeout"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    assert has_element?(view, "#tools-protocols")
    assert has_element?(view, "#tools-registry-shell_command")
    assert has_element?(view, "#tools-bundle-files_read")
    assert has_element?(view, "#tools-policy-#{policy.id}")
    assert has_element?(view, "#tools-credential-pool-#{pool.id}")
    assert has_element?(view, "#tools-mcp-#{server.id}")
    assert has_element?(view, "#tools-webhook-#{webhook.id}")
    assert has_element?(view, "#tools-protocol-status")

    html = render(view)
    assert html =~ "shell_command"
    assert html =~ "files_read"
    assert html =~ "bundles files_read"
    assert html =~ "network example.com / shell mix test"
    assert html =~ "files lib / env MIX_ENV"
    assert html =~ "warnings 0"
    assert html =~ "Provider Secrets"
    assert html =~ "env OPENAI_API_KEY"
    assert html =~ "Docs MCP"
    assert html =~ "http / sandboxed / healthy"
    assert html =~ "tools search_docs / env MCP_DOCS_TOKEN"
    assert html =~ "Deploy Review"
    assert html =~ "token env HYDRA_WEBHOOK_TOKEN"
    assert html =~ "last error %{&quot;reason&quot; =&gt; &quot;timeout&quot;}"
    assert html =~ "active 1"
  end

  test "creates a policy from the tools protocols editor and shows warnings", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-policy-editor"})

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#tools-policy-editor",
        policy: %{
          allowed_tools: "shell_command",
          shell_allowlist: "*",
          side_effect_classes: "shell",
          requires_approval: "true"
        }
      )
      |> render_submit()

    assert html =~ "Tool policy created"
    assert html =~ "warnings 1"
    assert html =~ "Shell allows every command"
  end

  test "creates connector accounts and approval-gated actions from tools protocols", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-connectors"})
    agent = agent_fixture(workspace, %{name: "Social Agent", slug: "social-agent"})

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#tools-connector-editor",
        connector: %{
          provider: "email",
          slug: "primary-email",
          display_name: "Primary Email",
          credential_env: "EMAIL_ACCESS_TOKEN"
        }
      )
      |> render_submit()

    assert html =~ "Connector created"
    assert html =~ "Primary Email"
    assert html =~ "Connector Setup Guide"
    assert html =~ "Store the access token in EMAIL_ACCESS_TOKEN"
    assert html =~ "tweet.write"

    [account] = Connectors.list_accounts(workspace.id)

    html =
      view
      |> form("#tools-connector-#{account.id} form",
        connector_grant: %{
          account_id: account.id,
          agent_id: agent.id,
          action: "send",
          mode: "approval_required"
        }
      )
      |> render_submit()

    assert html =~ "Connector permission granted"
    assert html =~ "grants 1"

    html =
      view
      |> element("#tools-connector-#{account.id} button", "Check Health")
      |> render_click()

    assert html =~ "Connector health checked"
    assert html =~ "missing_secret_env"

    html =
      view
      |> form("#tools-connector-action-editor",
        connector_action: %{
          account_id: account.id,
          agent_id: agent.id,
          action: "send",
          approval_mode: "approval_required",
          input: ~s({"to":"team@example.com","body":"Hello"})
        }
      )
      |> render_submit()

    assert html =~ "Connector action recorded"
    assert html =~ "awaiting_approval"

    [action] = Connectors.list_actions(workspace.id)

    html =
      view
      |> element("#tools-connector-action-#{action.id} button", "Approve")
      |> render_click()

    assert html =~ "Connector action approved"
    assert html =~ "completed"
  end

  test "creates connector accounts with config json from tools protocols", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-connector-config"})

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#tools-connector-editor",
        connector: %{
          provider: "linkedin",
          slug: "linkedin-main",
          display_name: "LinkedIn Main",
          credential_env: "LINKEDIN_ACCESS_TOKEN",
          config: ~s({"author_urn":"urn:li:person:abc123"})
        }
      )
      |> render_submit()

    assert html =~ "Connector created"
    assert html =~ "author_urn"
    assert html =~ "LinkedIn author URN"
    assert html =~ "w_member_social"

    [account] = Connectors.list_accounts(workspace.id)
    assert account.config["author_urn"] == "urn:li:person:abc123"
  end

  test "rejects connector config that is not a json object", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-connector-invalid-config"})

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#tools-connector-editor",
        connector: %{
          provider: "calendar",
          slug: "calendar-main",
          display_name: "Calendar Main",
          config: "not json"
        }
      )
      |> render_submit()

    assert html =~ "config must be a JSON object"
    assert Connectors.list_accounts(workspace.id) == []
  end

  test "scans and installs raw skill imports from tools protocols", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-skill-imports"})

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#tools-skill-import-editor",
        skill_import: %{
          source_type: "raw",
          markdown: """
          ---
          name: Tools Import Skill
          required_tools: [knowledge_read]
          ---
          # Tools Import Skill
          Summarize evidence.
          """
        }
      )
      |> render_submit()

    assert html =~ "Skill import scanned"
    assert html =~ "Tools Import Skill"
    assert has_element?(view, "#tools-skill-imports")
  end

  test "refreshes MCP discovery from the tools protocols page", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-mcp-discovery"})

    response_json =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"tools" => [%{"name" => "search_docs"}]}
      })

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Local MCP",
        slug: "local-mcp-discovery",
        status: "active",
        transport: "stdio",
        config: %{
          "command" => [
            "sh",
            "-c",
            "read line; printf '%s\\n' \"$0\"",
            response_json
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    assert has_element?(view, "#tools-mcp-discover-#{server.id}")

    view |> element("#tools-mcp-discover-#{server.id}") |> render_click()

    updated = MCP.get_server!(server.id)
    assert updated.health_status == "healthy"
    assert updated.metadata["discovery"]["tools"] == [%{"name" => "search_docs"}]

    html = render(view)
    assert html =~ "MCP discovery updated"
    assert html =~ "discovered tools search_docs"
  end

  test "renders and stops persistent stdio MCP sessions from the tools protocols page", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-tools-mcp-session"})

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Persistent MCP",
        slug: "persistent-mcp-session",
        status: "active",
        transport: "stdio",
        config: %{
          "persistent" => true,
          "command" => [
            "sh",
            "-c",
            ~S"""
            count=0; while IFS= read -r line; do count=$((count + 1)); printf '{"jsonrpc":"2.0","id":1,"result":{"count":%s}}\n' "$count"; done
            """
          ]
        },
        include_tools: ["ping"]
      })

    assert {:ok, response} =
             MCP.execute_tool(server, "ping", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => File.cwd!()
             })

    assert response["result"]["count"] == 1

    {:ok, view, html} = live(conn, ~p"/control/tools?workspace_id=#{workspace.id}")

    assert html =~ "session active / requests 1"
    assert has_element?(view, "#tools-mcp-session-#{server.id}")
    assert has_element?(view, "#tools-mcp-session-stop-#{server.id}")

    html =
      view
      |> element("#tools-mcp-session-stop-#{server.id}")
      |> render_click()

    assert html =~ "MCP stdio session stopped"
    assert MCP.stdio_session_status(server)["active"] == false

    html = render(view)
    assert html =~ ~r/session\s+inactive/
    assert html =~ ~r/requests\s+0/
  end
end
