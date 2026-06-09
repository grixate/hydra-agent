defmodule HydraAgentWeb.PluginControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "scans installs and lists workspace plugins", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "plugin-api"})
    plugin_dir = plugin_fixture()

    scan_conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/plugins/scan", %{
        path: plugin_dir
      })

    assert %{"data" => %{"manifest" => %{"slug" => "api-plugin"}}} =
             json_response(scan_conn, 200)

    install_conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/plugins/install", %{
        path: plugin_dir,
        approved_by: "operator"
      })

    assert %{"data" => %{"id" => id, "status" => "installed", "capabilities" => capabilities}} =
             json_response(install_conn, 201)

    assert Enum.any?(capabilities, &(&1["name"] == "api_plugin_tool"))

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/plugins/#{id}/enable", %{
        approved_by: "operator"
      })

    assert %{"data" => %{"status" => "enabled"}} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/tools")
    assert %{"data" => tools} = json_response(conn, 200)
    assert Enum.any?(tools, &(&1["name"] == "api_plugin_tool"))

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/client_surfaces")
    assert %{"data" => [%{"name" => "api-studio"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/web_routes")
    assert %{"data" => [%{"name" => "api-studio"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/client_contract")

    assert %{
             "data" => %{
               "plugins" => [%{"slug" => "api-plugin", "api_scopes" => ["plugins:read"]}],
               "client_surfaces" => [%{"name" => "api-studio"}]
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/#{id}/doctor")

    assert %{"data" => %{"readiness" => "ready", "capability_counts" => %{"tool" => 1}}} =
             json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/#{id}/config")

    assert %{"data" => %{"config" => %{}, "config_schema" => %{"required" => []}}} =
             json_response(conn, 200)

    conn =
      put(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/plugins/#{id}/config", %{
        config: %{"mode" => "standard"},
        configured_by: "operator"
      })

    assert %{"data" => %{"config" => %{"mode" => "standard"}, "configured_by" => "operator"}} =
             json_response(conn, 200)
  end

  test "exposes plugin manifest schema", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/plugins/manifest_schema")

    assert %{
             "data" => %{
               "plugin_version" => 1,
               "capability_kinds" => kinds,
               "capability_fields" => %{"client_surfaces" => "client_surface"},
               "source_security" => %{"secret_storage" => _}
             }
           } = json_response(conn, 200)

    assert "client_surface" in kinds
  end

  defp plugin_fixture do
    root = Path.join(System.tmp_dir!(), "hydra-plugin-api-#{System.unique_integer([:positive])}")
    manifest_dir = Path.join([root, ".hydra-plugin"])
    File.mkdir_p!(manifest_dir)

    manifest = %{
      "plugin_version" => 1,
      "slug" => "api-plugin",
      "name" => "API Plugin",
      "version" => "0.1.0",
      "package_type" => "hybrid",
      "trust_level" => "external",
      "permissions" => %{
        "side_effect_classes" => ["read_only"],
        "requires_approval" => true,
        "env_refs" => [],
        "api_scopes" => ["plugins:read"]
      },
      "config_schema" => %{
        "type" => "object",
        "properties" => %{"mode" => %{"type" => "string"}},
        "required" => []
      },
      "compatibility" => %{"hydra_version" => ">=0.1.0 <0.2.0"},
      "dependencies" => [],
      "capabilities" => %{
        "tools" => [
          %{
            "name" => "api_plugin_tool",
            "side_effect_class" => "read_only",
            "execution" => %{"type" => "project_skill"}
          }
        ],
        "tool_bundles" => [],
        "agent_packs" => [],
        "skills" => [],
        "mcp_servers" => [],
        "connectors" => [],
        "room_channels" => [],
        "cli_commands" => [],
        "client_surfaces" => [
          %{
            "name" => "api-studio",
            "kind" => "external_url",
            "path" => "/plugins/api-studio",
            "surface" => "workspace",
            "required_scopes" => ["plugins:read"],
            "entrypoint" => %{"type" => "external_url", "url" => "http://localhost:4001"}
          }
        ],
        "migrations" => []
      }
    }

    File.write!(Path.join(manifest_dir, "plugin.json"), Jason.encode!(manifest))
    root
  end
end
