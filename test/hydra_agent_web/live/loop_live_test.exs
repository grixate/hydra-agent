defmodule HydraAgentWeb.LoopLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Loops

  test "renders empty loops page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/loops")

    assert html =~ "Loops"
    assert html =~ "No workspaces yet."
  end

  test "renders loop detail with guardrails, state, and linked runs", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-loop-live"})

    agent =
      agent_fixture(workspace, %{name: "Loop Steward", slug: "loop-steward", role: "supervisor"})

    loop =
      loop_fixture(workspace, %{
        supervisor_agent: agent,
        name: "Runtime Doctor Loop",
        slug: "runtime-doctor-live",
        purpose: "Keep runtime health visible.",
        state: %{"cursor" => "last-check"},
        last_error: %{"reason" => "approval_required"}
      })

    run_fixture(workspace, %{
      supervisor_agent_id: agent.id,
      loop_id: loop.id,
      title: "Loop tick: Runtime Doctor Loop",
      goal: "Keep runtime health visible.",
      metadata: %{"loop_stop_reason" => "no_work"}
    })

    {:ok, view, html} = live(conn, ~p"/control/loops/#{loop.id}?workspace_id=#{workspace.id}")

    assert html =~ "Governed loops"
    assert html =~ "Runtime Doctor Loop"
    assert html =~ "Keep runtime health visible."
    assert html =~ "approval_required"
    assert html =~ "last-check"
    assert has_element?(view, "#loop-detail-#{loop.id}")
  end

  test "creates loop from recipe and pauses it", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-loop-recipe-live"})

    agent =
      agent_fixture(workspace, %{
        name: "Recipe Steward",
        slug: "recipe-steward",
        role: "supervisor"
      })

    {:ok, view, _html} = live(conn, ~p"/control/loops?workspace_id=#{workspace.id}")

    view
    |> form("#loop-recipe-runtime_doctor_loop", %{
      "recipe" => %{"recipe_id" => "runtime_doctor_loop", "supervisor_agent_id" => agent.id}
    })
    |> render_submit()

    [loop] = Loops.list_loops(workspace.id)
    assert loop.slug == "runtime-doctor-loop"

    html = render(view)
    assert html =~ "Loop recipe created"
    assert html =~ "Runtime Doctor Loop"

    view
    |> element("#loop-row-#{loop.id}")
    |> render_click()

    view
    |> element("button", "Pause")
    |> render_click()

    assert Loops.get_loop!(loop.id).status == "paused"
  end
end
