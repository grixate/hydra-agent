defmodule HydraAgentWeb.MissionLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mission-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/missions?workspace_id=not-an-id")

    assert html =~ "Mission Studio"
    assert render(view) =~ workspace.name
  end

  test "creates and starts a mission from Mission Studio", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-mission-live"})

    {:ok, view, html} = live(conn, ~p"/control/missions?workspace_id=#{workspace.id}")

    assert html =~ "Mission Studio"
    assert has_element?(view, "#mission-create-form")

    view
    |> form("#mission-create-form",
      mission: %{
        title: "Close V2 gaps",
        objective: "Move the management interface toward the final concept",
        mission_type: "coding",
        priority: 70
      }
    )
    |> render_submit()

    mission = Runtime.list_missions(workspace.id, q: "Close V2") |> List.first()
    assert mission.title == "Close V2 gaps"

    {:ok, view, _html} =
      live(conn, ~p"/control/missions/#{mission.id}?workspace_id=#{workspace.id}")

    view |> element("#mission-start-#{mission.id}") |> render_click()

    mission = Runtime.get_mission!(mission.id)
    assert mission.status == "running"
    assert [_run] = mission.runs
  end

  test "run index filters by mission and exposes trace links", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-index-live"})

    {:ok, mission} =
      Runtime.create_mission(%{
        workspace_id: workspace.id,
        title: "Traceable Mission",
        objective: "Check run index"
      })

    {:ok, run} = Runtime.create_mission_run(mission, %{title: "Traceable Run"})
    other_run = run_fixture(workspace, %{title: "Other Run"})

    {:ok, view, html} =
      live(conn, ~p"/control/runs?workspace_id=#{workspace.id}&mission_id=#{mission.id}")

    assert html =~ "Run Index"
    assert has_element?(view, "#run-index-row-#{run.id}")
    refute has_element?(view, "#run-index-row-#{other_run.id}")
    assert render(view) =~ "Traceable Mission"
  end

  test "run index falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-index-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/runs?workspace_id=not-an-id")

    assert html =~ "Run Index"
    assert render(view) =~ workspace.name
  end
end
