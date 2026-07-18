defmodule HydraAgentWeb.Plugs.ApiAuthTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.ApiCredentials

  setup do
    original_config = Application.get_env(:hydra_agent, :api_auth)
    original_token = System.get_env("HYDRA_TEST_API_TOKEN")

    on_exit(fn ->
      if original_config do
        Application.put_env(:hydra_agent, :api_auth, original_config)
      else
        Application.delete_env(:hydra_agent, :api_auth)
      end

      if original_token do
        System.put_env("HYDRA_TEST_API_TOKEN", original_token)
      else
        System.delete_env("HYDRA_TEST_API_TOKEN")
      end
    end)

    :ok
  end

  test "allows API requests when auth is disabled", %{conn: conn} do
    Application.put_env(:hydra_agent, :api_auth,
      enabled?: false,
      token_env: "HYDRA_TEST_API_TOKEN"
    )

    conn = get(conn, ~p"/api/health")

    assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)
  end

  test "requires matching bearer token when auth is enabled", %{conn: conn} do
    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_TEST_API_TOKEN"
    )

    System.put_env("HYDRA_TEST_API_TOKEN", "secret-token")

    conn = get(conn, ~p"/api/health")
    assert %{"errors" => %{"reason" => "missing_bearer_token"}} = json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer wrong")
      |> get(~p"/api/health")

    assert %{"errors" => %{"reason" => "invalid_bearer_token"}} = json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer secret-token")
      |> get(~p"/api/health")

    assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)
  end

  test "fails closed when auth is enabled but the token env is missing", %{conn: conn} do
    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_TEST_API_TOKEN"
    )

    System.delete_env("HYDRA_TEST_API_TOKEN")

    conn =
      conn
      |> put_req_header("authorization", "Bearer anything")
      |> get(~p"/api/health")

    assert %{"errors" => %{"reason" => "missing_secret_env", "env" => "HYDRA_TEST_API_TOKEN"}} =
             json_response(conn, 503)
  end

  test "fails closed when enabled without a token env name", %{conn: conn} do
    Application.put_env(:hydra_agent, :api_auth, enabled?: true, token_env: nil)

    conn = get(conn, ~p"/api/health")

    assert %{"errors" => %{"reason" => "missing_api_auth_token_env"}} = json_response(conn, 503)
  end

  test "accepts scoped database tokens and rejects cross-workspace use", %{conn: conn} do
    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_TEST_API_TOKEN"
    )

    System.put_env("HYDRA_TEST_API_TOKEN", "break-glass-token")
    allowed = workspace_fixture(%{slug: "api-token-allowed"})
    denied = workspace_fixture(%{slug: "api-token-denied"})

    {:ok, %{token: raw}} =
      ApiCredentials.issue_token(%{
        name: "Scoped reader",
        workspace_id: allowed.id,
        permissions: ["read"]
      })

    allowed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/api/v1/workspaces/#{allowed.id}/doctor")

    assert response(allowed_conn, 200)

    workspace_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/api/v1/workspaces/#{allowed.id}")

    assert %{"data" => %{"id" => workspace_id}} = json_response(workspace_conn, 200)
    assert workspace_id == allowed.id

    denied_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/api/v1/workspaces/#{denied.id}/doctor")

    assert %{"errors" => %{"reason" => "workspace_scope_mismatch"}} =
             json_response(denied_conn, 403)

    write_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post("/api/v1/workspaces/#{allowed.id}/agents", %{})

    assert %{"errors" => %{"reason" => "insufficient_permission"}} =
             json_response(write_conn, 403)
  end
end
