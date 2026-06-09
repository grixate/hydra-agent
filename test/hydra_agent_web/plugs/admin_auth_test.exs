defmodule HydraAgentWeb.Plugs.AdminAuthTest do
  use HydraAgentWeb.ConnCase

  setup do
    original_config = Application.get_env(:hydra_agent, :browser_auth)
    original_username = System.get_env("HYDRA_TEST_ADMIN_USERNAME")
    original_password = System.get_env("HYDRA_TEST_ADMIN_PASSWORD")

    Application.put_env(:hydra_agent, :browser_auth,
      enabled?: true,
      username_env: "HYDRA_TEST_ADMIN_USERNAME",
      password_env: "HYDRA_TEST_ADMIN_PASSWORD",
      session_ttl_seconds: 28_800,
      max_failed_attempts: 2,
      rate_limit_window_seconds: 300
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:hydra_agent, :browser_auth, original_config)
      else
        Application.delete_env(:hydra_agent, :browser_auth)
      end

      restore_env("HYDRA_TEST_ADMIN_USERNAME", original_username)
      restore_env("HYDRA_TEST_ADMIN_PASSWORD", original_password)
    end)

    :ok
  end

  test "redirects protected browser routes to login", %{conn: conn} do
    System.put_env("HYDRA_TEST_ADMIN_USERNAME", "limited-admin")
    System.put_env("HYDRA_TEST_ADMIN_PASSWORD", "secret")

    conn = get(conn, ~p"/control")

    assert redirected_to(conn) == "/login?return_to=/control"
  end

  test "fails closed when admin credentials are not configured", %{conn: conn} do
    System.delete_env("HYDRA_TEST_ADMIN_USERNAME")
    System.put_env("HYDRA_TEST_ADMIN_PASSWORD", "secret")

    conn = get(conn, ~p"/control")

    assert response(conn, 503) =~ "Hydra admin auth is not configured"
    assert response(conn, 503) =~ "HYDRA_TEST_ADMIN_USERNAME"
  end

  test "signs in with matching env-backed credentials and logout clears the session", %{
    conn: conn
  } do
    System.put_env("HYDRA_TEST_ADMIN_USERNAME", "admin")
    System.put_env("HYDRA_TEST_ADMIN_PASSWORD", "secret")

    conn =
      post(conn, ~p"/login", %{
        "username" => "admin",
        "password" => "secret",
        "return_to" => "/control"
      })

    assert redirected_to(conn) == "/control"

    conn =
      conn
      |> recycle()
      |> get(~p"/control")

    assert html_response(conn, 200) =~ "Hydra"

    conn =
      conn
      |> recycle()
      |> delete(~p"/logout")

    assert redirected_to(conn) == "/login"

    conn =
      conn
      |> recycle()
      |> get(~p"/control")

    assert redirected_to(conn) == "/login?return_to=/control"
  end

  test "rejects invalid credentials", %{conn: conn} do
    System.put_env("HYDRA_TEST_ADMIN_USERNAME", "admin")
    System.put_env("HYDRA_TEST_ADMIN_PASSWORD", "secret")

    conn =
      post(conn, ~p"/login", %{
        "username" => "admin",
        "password" => "wrong",
        "return_to" => "/control"
      })

    assert html_response(conn, 401) =~ "Sign in to Hydra"
  end

  test "rate limits repeated invalid credentials", %{conn: conn} do
    System.put_env("HYDRA_TEST_ADMIN_USERNAME", "admin")
    System.put_env("HYDRA_TEST_ADMIN_PASSWORD", "secret")
    HydraAgentWeb.AdminAuth.clear_failed_attempts("admin:127.0.0.1")

    for _attempt <- 1..2 do
      conn =
        post(build_conn(), ~p"/login", %{
          "username" => "admin",
          "password" => "wrong",
          "return_to" => "/control"
        })

      assert html_response(conn, 401) =~ "Sign in to Hydra"
    end

    conn =
      post(conn, ~p"/login", %{
        "username" => "admin",
        "password" => "wrong",
        "return_to" => "/control"
      })

    assert html_response(conn, 429) =~ "Sign in to Hydra"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
