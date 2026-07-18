defmodule HydraAgentWeb.PageControllerTest do
  use HydraAgentWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Hydra Agent Runtime"

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "connect-src 'self'"
    refute csp =~ "connect-src 'self' ws: wss:"
    assert csp =~ "frame-src 'none'"

    assert get_resp_header(conn, "permissions-policy") == [
             "camera=(), geolocation=(), microphone=(), payment=(), usb=()"
           ]

    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
  end
end
