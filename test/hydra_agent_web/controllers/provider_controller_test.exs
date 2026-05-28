defmodule HydraAgentWeb.ProviderControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  test "creates credential pools and attaches providers", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-provider-api"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/credential_pools", %{
        name: "OpenAI Production",
        kind: "provider",
        env_vars: ["OPENAI_API_KEY"]
      })

    assert %{"data" => %{"id" => pool_id, "slug" => "openai-production"}} =
             json_response(conn, 201)

    conn =
      post(
        build_conn(),
        ~p"/api/v1/workspaces/#{workspace.id}/credential_pools/#{pool_id}/items",
        %{
          env_var: "OPENAI_BACKUP_KEY",
          priority: 10
        }
      )

    assert %{"data" => %{"env_var" => "OPENAI_BACKUP_KEY", "status" => "active"}} =
             json_response(conn, 201)

    conn =
      post(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/providers", %{
        name: "OpenAI",
        kind: "openai_compatible",
        model: "gpt-4.1-mini",
        api_key_env: "OPENAI_API_KEY",
        credential_pool_id: pool_id
      })

    assert %{"data" => %{"credential_pool_id" => ^pool_id}} = json_response(conn, 201)

    conn = get(build_conn(), ~p"/api/v1/workspaces/#{workspace.id}/providers")
    assert %{"data" => [%{"credential_pool" => %{"id" => ^pool_id}}]} = json_response(conn, 200)
  end

  test "workspace-scoped provider routes reject foreign credential pools and providers", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-provider-scope"})
    other_workspace = workspace_fixture(%{name: "Other Ops", slug: "other-ops-provider-scope"})

    {:ok, pool} =
      HydraAgent.Runtime.create_credential_pool(%{
        workspace_id: workspace.id,
        name: "Scoped Pool",
        env_vars: ["HYDRA_SCOPED_KEY"]
      })

    {:ok, provider} =
      HydraAgent.Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "Scoped Provider",
        kind: "mock",
        model: "mock-model",
        credential_pool_id: pool.id
      })

    assert_error_sent 404, fn ->
      post(
        conn,
        ~p"/api/v1/workspaces/#{other_workspace.id}/credential_pools/#{pool.id}/items",
        %{
          env_var: "HYDRA_OTHER_KEY"
        }
      )
    end

    assert_error_sent 404, fn ->
      get(build_conn(), ~p"/api/v1/workspaces/#{other_workspace.id}/providers/#{provider.id}")
    end
  end

  test "rejects invalid credential env var names", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-provider-api-invalid"})

    conn =
      post(conn, ~p"/api/v1/workspaces/#{workspace.id}/credential_pools", %{
        name: "Bad Pool",
        env_vars: ["plain-secret"]
      })

    assert %{"errors" => %{"env_vars" => ["must contain environment variable names"]}} =
             json_response(conn, 422)
  end
end
