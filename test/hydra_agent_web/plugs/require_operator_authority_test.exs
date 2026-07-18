defmodule HydraAgentWeb.Plugs.RequireOperatorAuthorityTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.ApiCredentials

  setup do
    original_config = Application.get_env(:hydra_agent, :api_auth)
    original_token = System.get_env("HYDRA_OPERATOR_AUTH_TEST_TOKEN")

    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_OPERATOR_AUTH_TEST_TOKEN"
    )

    System.put_env("HYDRA_OPERATOR_AUTH_TEST_TOKEN", "operator-break-glass-token")

    on_exit(fn ->
      if original_config do
        Application.put_env(:hydra_agent, :api_auth, original_config)
      else
        Application.delete_env(:hydra_agent, :api_auth)
      end

      if original_token do
        System.put_env("HYDRA_OPERATOR_AUTH_TEST_TOKEN", original_token)
      else
        System.delete_env("HYDRA_OPERATOR_AUTH_TEST_TOKEN")
      end
    end)

    workspace = workspace_fixture(%{slug: "operator-authority-boundary"})

    {:ok, %{token: workspace_token}} =
      ApiCredentials.issue_token(%{
        name: "Workspace writer",
        workspace_id: workspace.id,
        permissions: ["write"]
      })

    {:ok, workspace: workspace, workspace_token: workspace_token}
  end

  test "workspace write tokens are denied across operator-only API actions", %{
    workspace: workspace,
    workspace_token: token
  } do
    workspace_id = workspace.id

    protected_paths = [
      "/api/v1/workspaces/#{workspace_id}/providers",
      "/api/v1/workspaces/#{workspace_id}/credential_pools",
      "/api/v1/workspaces/#{workspace_id}/credential_pools/999999/items",
      "/api/v1/workspaces/#{workspace_id}/mcp_servers",
      "/api/v1/workspaces/#{workspace_id}/tool_policies",
      "/api/v1/workspaces/#{workspace_id}/agent_builder/create",
      "/api/v1/workspaces/#{workspace_id}/agents",
      "/api/v1/workspaces/#{workspace_id}/agents/import_pack",
      "/api/v1/workspaces/#{workspace_id}/runs/999999/execute_next",
      "/api/v1/workspaces/#{workspace_id}/runs/999999/execute_parallel",
      "/api/v1/workspaces/#{workspace_id}/runs/999999/start_worker",
      "/api/v1/workspaces/#{workspace_id}/runs/999999/stop_worker",
      "/api/v1/workspaces/#{workspace_id}/runs/999999/steps/999999/approve",
      "/api/v1/workspaces/#{workspace_id}/checkpoints/999999/restore",
      "/api/v1/workspaces/#{workspace_id}/connectors",
      "/api/v1/workspaces/#{workspace_id}/connectors/999999/agent_grants",
      "/api/v1/workspaces/#{workspace_id}/connector_actions/999999/approve",
      "/api/v1/workspaces/#{workspace_id}/rooms/999999/channel_bindings",
      "/api/v1/workspaces/#{workspace_id}/rooms/999999/channel_bindings/999999/retry",
      "/api/v1/workspaces/#{workspace_id}/rooms/999999/deliveries/999999/retry",
      "/api/v1/workspaces/#{workspace_id}/rooms/999999/messages/999999/approve",
      "/api/v1/workspaces/#{workspace_id}/skill_imports/999999/approve",
      "/api/v1/workspaces/#{workspace_id}/skills/code_skill",
      "/api/v1/workspaces/#{workspace_id}/skills/import_directory"
    ]

    Enum.each(protected_paths, fn path ->
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(path, %{})

      assert %{"errors" => %{"reason" => "operator_authority_required"}} =
               json_response(conn, 403),
             "expected operator boundary for #{path}"
    end)
  end

  test "the environment token can perform an operator-only action", %{workspace: workspace} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer operator-break-glass-token")
      |> post("/api/v1/workspaces/#{workspace.id}/providers", provider_attrs("operator-provider"))

    assert %{"data" => %{"name" => "operator-provider"}} = json_response(conn, 201)
  end

  test "auth-disabled development remains usable", %{workspace: workspace} do
    Application.put_env(:hydra_agent, :api_auth,
      enabled?: false,
      token_env: "HYDRA_OPERATOR_AUTH_TEST_TOKEN"
    )

    conn =
      post(
        build_conn(),
        "/api/v1/workspaces/#{workspace.id}/providers",
        provider_attrs("development-provider")
      )

    assert %{"data" => %{"name" => "development-provider"}} = json_response(conn, 201)
  end

  test "ordinary workspace data writes remain available to workspace tokens", %{
    workspace: workspace,
    workspace_token: token
  } do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/workspaces/#{workspace.id}/runs", %{
        "title" => "Data-only run",
        "goal" => "Prepare a plan"
      })

    assert %{"data" => %{"id" => run_id, "title" => "Data-only run"}} =
             json_response(conn, 201)

    plan_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/workspaces/#{workspace.id}/runs/#{run_id}/plan", %{
        "steps" => [
          %{
            "title" => "Draft the plan",
            "tool_name" => "noop",
            "side_effect_class" => "read_only",
            "input" => %{}
          }
        ]
      })

    assert %{"data" => %{"steps" => [%{"title" => "Draft the plan"}]}} =
             json_response(plan_conn, 200)
  end

  defp provider_attrs(name) do
    %{
      "name" => name,
      "kind" => "openai_compatible",
      "model" => "test-model",
      "api_key_env" => "HYDRA_OPERATOR_AUTH_TEST_PROVIDER_KEY"
    }
  end
end
