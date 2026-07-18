defmodule HydraAgentWeb.HealthControllerTest do
  use HydraAgentWeb.ConnCase

  test "public liveness and readiness expose only operational state", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/healthz") |> json_response(200)

    assert %{
             "status" => "ready",
             "checks" => %{"database" => true, "jobs" => true, "migrations" => true}
           } = conn |> recycle() |> get(~p"/readyz") |> json_response(200)
  end

  test "telemetry metrics remain behind API authentication", %{conn: conn} do
    original = Application.get_env(:hydra_agent, :api_auth)
    Application.put_env(:hydra_agent, :api_auth, enabled?: true, token_env: nil)
    on_exit(fn -> Application.put_env(:hydra_agent, :api_auth, original) end)

    assert %{"errors" => %{"reason" => "missing_api_auth_token_env"}} =
             conn |> get(~p"/api/metrics") |> json_response(503)
  end
end
