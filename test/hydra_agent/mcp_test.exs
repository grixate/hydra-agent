defmodule HydraAgent.MCPTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{MCP, Runtime}

  test "creates and lists MCP server records" do
    workspace = workspace_fixture()

    assert {:ok, server} =
             MCP.create_server(%{
               workspace_id: workspace.id,
               name: "Docs MCP",
               slug: "docs-mcp",
               transport: "http",
               config: %{"url" => "https://mcp.example.com"},
               env_refs: ["MCP_DOCS_TOKEN"],
               include_tools: ["search_docs"],
               approval_sensitive: true
             })

    assert [listed] = MCP.list_servers(workspace.id)
    assert listed.id == server.id
    assert listed.status == "inactive"
    assert listed.health_status == "unknown"
  end

  test "updates health metadata without exposing secrets" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-update",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"]
      })

    assert {:ok, updated} =
             MCP.update_server(server, %{
               health_status: "unhealthy",
               last_error: %{"reason" => "connection_failed"}
             })

    assert updated.env_refs == ["MCP_DOCS_TOKEN"]
    assert updated.last_error["reason"] == "connection_failed"
  end

  test "discovers HTTP MCP tools resources and prompts into health metadata" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Discover MCP",
        slug: "discover-mcp",
        status: "active",
        transport: "http",
        config: %{"url" => "http://mcp.test"},
        resource_access: true,
        prompt_access: true
      })

    plug = fn conn ->
      result =
        case conn.body_params["method"] do
          "tools/list" -> %{"tools" => [%{"name" => "search_docs"}]}
          "resources/list" -> %{"resources" => [%{"uri" => "file://guide.md"}]}
          "prompts/list" -> %{"prompts" => [%{"name" => "summarize"}]}
        end

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => conn.body_params["id"], "result" => result})
      )
    end

    assert {:ok, updated} =
             MCP.discover_server(server, %{"workspace_id" => workspace.id},
               req_options: [plug: plug]
             )

    assert updated.health_status == "healthy"
    assert updated.last_error == %{}
    assert updated.last_checked_at
    assert updated.metadata["discovery"]["tools"] == [%{"name" => "search_docs"}]
    assert updated.metadata["discovery"]["resources"] == [%{"uri" => "file://guide.md"}]
    assert updated.metadata["discovery"]["prompts"] == [%{"name" => "summarize"}]
    assert updated.metadata["discovered_at"]
  end

  test "records unhealthy MCP discovery errors" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Broken MCP",
        slug: "broken-mcp",
        status: "active",
        transport: "http",
        config: %{"url" => "http://mcp.test"}
      })

    plug = fn conn ->
      Plug.Conn.send_resp(
        conn,
        500,
        Jason.encode!(%{"error" => %{"message" => "auth failed", "token" => "secret"}})
      )
    end

    assert {:error, %{"reason" => "mcp_http_error", "server_id" => server_id}} =
             MCP.discover_server(server, %{"workspace_id" => workspace.id},
               req_options: [plug: plug]
             )

    assert server_id == server.id
    updated = MCP.get_server!(server.id)
    assert updated.health_status == "unhealthy"
    assert updated.last_checked_at
    assert updated.last_error["reason"] == "mcp_http_error"
    assert updated.last_error["body"]["error"]["message"] == "auth failed"
    assert updated.last_error["body"]["error"]["token"] == "[REDACTED]"
  end

  test "executes active HTTP MCP tool calls with redacted audit events" do
    %{workspace: workspace, agent: agent, run: run} = runtime_fixture()
    {:ok, step} = Runtime.create_run_step(run, %{index: 0, title: "MCP call"})
    System.put_env("MCP_TEST_TOKEN", "test-secret")

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-exec",
        status: "active",
        transport: "http",
        config: %{"url" => "http://mcp.test", "bearer_env" => "MCP_TEST_TOKEN"},
        env_refs: ["MCP_TEST_TOKEN"],
        include_tools: ["search_docs"]
      })

    plug = fn conn ->
      assert ["Bearer test-secret"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.body_params["method"] == "tools/call"
      assert conn.body_params["params"]["name"] == "search_docs"
      assert conn.body_params["params"]["arguments"]["api_key"] == "secret"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => conn.body_params["id"],
          "result" => %{"content" => [%{"type" => "text", "text" => "ok"}], "token" => "secret"}
        })
      )
    end

    assert {:ok, response} =
             MCP.execute_tool(
               server,
               "search_docs",
               %{"query" => "hydra", "api_key" => "secret"},
               %{
                 "workspace_id" => workspace.id,
                 "run_id" => run.id,
                 "run_step_id" => step.id,
                 "agent_id" => agent.id
               },
               req_options: [plug: plug]
             )

    assert response["result"]["content"] == [%{"type" => "text", "text" => "ok"}]

    events = Runtime.list_run_events(run.id)

    assert Enum.map(events, & &1.event_type) == [
             "run.created",
             "step.planned",
             "mcp.call.started",
             "mcp.call.completed"
           ]

    started = Enum.find(events, &(&1.event_type == "mcp.call.started"))
    completed = Enum.find(events, &(&1.event_type == "mcp.call.completed"))

    assert started.payload["payload"]["api_key"] == "[REDACTED]"
    assert completed.payload["payload"]["token"] == "[REDACTED]"
  after
    System.delete_env("MCP_TEST_TOKEN")
  end

  test "executes active stdio MCP tool calls with declared env refs and audit redaction" do
    %{workspace: workspace, agent: agent, run: run} = runtime_fixture()
    {:ok, step} = Runtime.create_run_step(run, %{index: 0, title: "MCP stdio call"})
    System.put_env("MCP_STDIO_TOKEN", "stdio-secret")

    response_json =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{
          "content" => [%{"type" => "text", "text" => "stdio ok"}],
          "token" => "stdio-secret"
        }
      })

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Local MCP",
        slug: "local-mcp-exec",
        status: "active",
        transport: "stdio",
        config: %{
          "command" => [
            "sh",
            "-c",
            "read line; test \"$MCP_STDIO_TOKEN\" = \"stdio-secret\" || exit 7; printf '%s\\n' \"$0\"",
            response_json
          ]
        },
        env_refs: ["MCP_STDIO_TOKEN"],
        include_tools: ["read_file"]
      })

    assert {:ok, response} =
             MCP.execute_tool(
               server,
               "read_file",
               %{"path" => "README.md", "token" => "stdio-secret"},
               %{
                 "workspace_id" => workspace.id,
                 "run_id" => run.id,
                 "run_step_id" => step.id,
                 "agent_id" => agent.id,
                 "workspace_root" => File.cwd!()
               }
             )

    assert response["result"]["content"] == [%{"type" => "text", "text" => "stdio ok"}]

    events = Runtime.list_run_events(run.id)
    started = Enum.find(events, &(&1.event_type == "mcp.call.started"))
    completed = Enum.find(events, &(&1.event_type == "mcp.call.completed"))

    assert started.payload["payload"]["token"] == "[REDACTED]"
    assert completed.payload["payload"]["token"] == "[REDACTED]"
  after
    System.delete_env("MCP_STDIO_TOKEN")
  end

  test "reuses persistent stdio MCP sessions across calls" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Persistent MCP",
        slug: "persistent-mcp-exec",
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

    assert {:ok, first} =
             MCP.execute_tool(server, "ping", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => File.cwd!()
             })

    assert first["result"]["count"] == 1

    assert [{pid, _value}] =
             Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server.id})

    assert {:ok, second} =
             MCP.execute_tool(server, "ping", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => File.cwd!()
             })

    assert second["result"]["count"] == 2

    assert [{^pid, _value}] =
             Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server.id})

    assert %{
             "active" => true,
             "request_count" => 2,
             "idle_timeout_ms" => 300_000
           } = MCP.stdio_session_status(server)

    assert :ok = MCP.stop_stdio_session(server)
    assert Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server.id}) == []
  end

  test "persistent stdio MCP sessions expire after idle timeout" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Idle MCP",
        slug: "idle-mcp-exec",
        status: "active",
        transport: "stdio",
        config: %{
          "persistent" => true,
          "idle_timeout_ms" => 20,
          "command" => [
            "sh",
            "-c",
            ~S"""
            while IFS= read -r line; do printf '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n'; done
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

    assert response["result"]["ok"] == true
    assert MCP.stdio_session_status(server)["active"] == true

    assert_eventually(fn ->
      assert MCP.stdio_session_status(server)["active"] == false
    end)
  end

  test "executes active SSE MCP tool calls from event-stream JSON-RPC responses" do
    %{workspace: workspace, agent: agent, run: run} = runtime_fixture()
    {:ok, step} = Runtime.create_run_step(run, %{index: 0, title: "MCP SSE call"})

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "SSE MCP",
        slug: "sse-mcp-exec",
        status: "active",
        transport: "sse",
        config: %{"url" => "http://mcp.test/sse"},
        include_tools: ["search_docs"]
      })

    plug = fn conn ->
      assert ["text/event-stream"] = Plug.Conn.get_req_header(conn, "accept")
      assert conn.body_params["method"] == "tools/call"
      assert conn.body_params["params"]["name"] == "search_docs"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        """
        event: message
        data: {"jsonrpc":"2.0","id":#{conn.body_params["id"]},"result":{"content":[{"type":"text","text":"sse ok"}],"token":"secret"}}

        data: [DONE]

        """
      )
    end

    assert {:ok, response} =
             MCP.execute_tool(
               server,
               "search_docs",
               %{"query" => "hydra"},
               %{
                 "workspace_id" => workspace.id,
                 "run_id" => run.id,
                 "run_step_id" => step.id,
                 "agent_id" => agent.id
               },
               req_options: [plug: plug]
             )

    assert response["result"]["content"] == [%{"type" => "text", "text" => "sse ok"}]

    events = Runtime.list_run_events(run.id)
    completed = Enum.find(events, &(&1.event_type == "mcp.call.completed"))
    assert completed.payload["payload"]["token"] == "[REDACTED]"
  end

  test "returns an MCP SSE error for invalid event-stream JSON" do
    workspace = workspace_fixture()

    {:ok, server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Bad SSE MCP",
        slug: "bad-sse-mcp",
        status: "active",
        transport: "sse",
        config: %{"url" => "http://mcp.test/sse"},
        include_tools: ["search_docs"]
      })

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: {not-json}\n\n")
    end

    assert {:error,
            %{
              "reason" => "mcp_json_rpc_error",
              "error" => %{"reason" => "mcp_sse_invalid_json"}
            }} =
             MCP.execute_tool(server, "search_docs", %{}, %{"workspace_id" => workspace.id},
               req_options: [plug: plug]
             )
  end

  test "fails closed for stdio MCP cwd and missing env refs" do
    workspace = workspace_fixture()

    {:ok, outside_cwd} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Outside MCP",
        slug: "outside-mcp",
        status: "active",
        transport: "stdio",
        config: %{"command" => ["sh", "-c", "printf '{}'"], "cwd" => "/"},
        include_tools: ["read_file"]
      })

    assert {:error, %{"reason" => "mcp_stdio_cwd_outside_workspace_root"}} =
             MCP.execute_tool(outside_cwd, "read_file", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => File.cwd!()
             })

    {:ok, missing_env} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Env MCP",
        slug: "env-mcp",
        status: "active",
        transport: "stdio",
        config: %{"command" => ["sh", "-c", "printf '{}'"]},
        env_refs: ["MCP_MISSING_STDIO_TOKEN"],
        include_tools: ["read_file"]
      })

    assert {:error, %{"reason" => "missing_secret_env", "env" => "MCP_MISSING_STDIO_TOKEN"}} =
             MCP.execute_tool(missing_env, "read_file", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => File.cwd!()
             })
  end

  test "blocks inactive or filtered MCP calls before transport execution" do
    workspace = workspace_fixture()

    {:ok, inactive} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Inactive MCP",
        slug: "inactive-mcp",
        status: "inactive",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        include_tools: ["search_docs"]
      })

    assert {:error, %{"reason" => "mcp_server_not_active"}} =
             MCP.execute_tool(inactive, "search_docs", %{}, %{"workspace_id" => workspace.id})

    {:ok, active} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Active MCP",
        slug: "active-mcp",
        status: "active",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        include_tools: ["search_docs"],
        exclude_tools: ["delete_docs"]
      })

    assert {:error, %{"reason" => "mcp_tool_not_included"}} =
             MCP.execute_tool(active, "write_docs", %{}, %{"workspace_id" => workspace.id})

    assert {:error, %{"reason" => "mcp_tool_excluded"}} =
             MCP.execute_tool(active, "delete_docs", %{}, %{"workspace_id" => workspace.id})
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 0), do: fun.()
end
