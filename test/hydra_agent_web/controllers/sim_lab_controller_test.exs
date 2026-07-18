defmodule HydraAgentWeb.SimLabControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint HydraAgentWeb.Endpoint

  test "GET the public demo renders the calm study cockpit" do
    html = build_conn() |> get("/demo/simulations") |> html_response(200)

    assert html =~ "Prepared study question"
    assert html =~ "Explore prepared context"
    assert html =~ "From question to decision."
  end

  test "GET observatory renders a canvas field without agent DOM nodes" do
    html =
      build_conn()
      |> get("/demo/simulations/certificate-visibility/observatory")
      |> html_response(200)

    assert html =~ "simulation-field"
    assert html =~ "tabindex=\"0\""
    assert html =~ "simulation-particles"
    assert html =~ "deterministic decisions"
    assert html =~ "0 <em>provider calls</em>"
    assert html =~ "Pattern flow"
    assert html =~ "id=\"grounding-row\""
    assert html =~ "id=\"zoom-lens\""
    assert html =~ "Resistance is about control, not certificates."
    refute html =~ "agent-node"
  end

  test "GET study workspace keeps the full research flow in one place" do
    html =
      build_conn() |> get("/demo/simulations/certificate-visibility") |> html_response(200)

    assert html =~ "What we know,"
    assert html =~ "Personas"
    assert html =~ "persona-swatch-0"
    refute html =~ "style="
    assert html =~ "Executable action patterns"
    assert html =~ "Recommendation,"
  end

  test "GET demo forecast exports an honest markdown artifact" do
    conn = build_conn() |> get("/demo/simulations/certificate-visibility/forecast.md")

    assert response(conn, 200) =~
             "# How will employees react if completed learning certificates become visible in their HR profile?"

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             "attachment; filename=hydra-demo-forecast.md"
           ]
  end
end
