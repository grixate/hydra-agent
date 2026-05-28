defmodule HydraAgentWeb.Plugs.ApiAuthTest do
  use HydraAgentWeb.ConnCase

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
end
