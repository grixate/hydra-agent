defmodule HydraAgentWeb.ConnectorControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Connectors

  test "creates connectors, checks health, and requests actions through workspace API", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-connector-api"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/connectors", %{
        provider: "notes",
        slug: "workspace-notes",
        display_name: "Workspace Notes"
      })

    assert %{"data" => %{"id" => account_id, "provider" => "notes"}} = json_response(conn, 201)

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/connectors/#{account_id}/health")

    assert %{"data" => %{"last_health" => %{"status" => "healthy"}}} = json_response(conn, 200)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/connectors/#{account_id}/actions",
        %{
          action: "append",
          input: %{"title" => "API Note", "content" => "Hydra API wrote this."}
        }
      )

    assert %{"data" => %{"id" => action_id, "status" => "awaiting_approval"}} =
             json_response(conn, 201)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/connector_actions/#{action_id}/approve"
      )

    assert %{"data" => %{"status" => "completed", "result" => %{"mode" => "workspace_note"}}} =
             json_response(conn, 200)
  end

  test "workspace-scoped connector routes reject foreign ids", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-connector-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-connector-scope"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notes",
        slug: "scoped-notes",
        display_name: "Scoped Notes"
      })

    {:ok, action} =
      Connectors.request_action(account, %{
        action: "append",
        input: %{"title" => "Scoped Note"}
      })

    assert_error_sent 404, fn ->
      post(conn, ~p"/api/v1/workspaces/#{other_workspace.id}/connectors/#{account.id}/health")
    end

    assert_error_sent 404, fn ->
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{other_workspace.id}/connectors/#{account.id}/actions",
        %{action: "append", input: %{"title" => "Nope"}}
      )
    end

    assert_error_sent 404, fn ->
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{other_workspace.id}/connector_actions/#{action.id}/approve"
      )
    end
  end

  test "connector specs expose setup metadata through API", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-connector-specs"})

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/connectors/specs")

    assert %{"data" => specs, "permission_presets" => presets} = json_response(conn, 200)
    assert Enum.any?(specs, &(&1["provider"] == "x" and "tweet.write" in &1["setup"]["scopes"]))
    assert Enum.any?(presets, &(&1["id"] == "approve_writes"))
  end

  test "grants agent connector permissions through workspace API", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-connector-grants-api"})
    agent = agent_fixture(workspace, %{slug: "api-social-agent"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "x",
        slug: "api-x",
        display_name: "API X"
      })

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/connectors/#{account.id}/agent_grants", %{
        agent_id: agent.id,
        action: "publish_post",
        mode: "approval_required"
      })

    assert %{
             "data" => %{
               "permission_grants" => grants,
               "readiness" => %{
                 "status" => "needs_attention",
                 "setup_guide" => %{"credential_env" => "X_ACCESS_TOKEN"}
               },
               "setup_guide" => %{"credential_env" => "X_ACCESS_TOKEN"}
             }
           } = json_response(conn, 200)

    assert get_in(grants, [to_string(agent.id), "actions"]) == ["publish_post"]
  end
end
