defmodule HydraAgentWeb.ControlLiveTest do
  use HydraAgentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime

  test "renders empty control plane", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Runtime Console"
    assert html =~ "No workspaces yet."
  end

  test "renders workspace runtime panels", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops"})

    {:ok, _run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Check runtime",
        goal: "Inspect current state"
      })

    {:ok, view, _html} = live(conn, ~p"/control")

    assert has_element?(view, "#control-plane")
    assert has_element?(view, "#control-runs")
    assert has_element?(view, "#control-graph")
    assert render(view) =~ "Check runtime"
  end

  test "run action buttons update durable run state", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops-actions"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Control action",
        goal: "Exercise run controls"
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    view |> element("#control-start-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#control-pause-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "paused"

    view |> element("#control-resume-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#control-cancel-run-#{run.id}") |> render_click()
    assert Runtime.get_run!(run.id).status == "canceled"
  end

  test "approval buttons update awaiting steps", %{conn: conn} do
    {:ok, workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops-approvals"})

    {:ok, run} =
      Runtime.create_run(%{
        workspace_id: workspace.id,
        title: "Approval run",
        goal: "Exercise approvals"
      })

    {:ok, approve_step} =
      Runtime.create_run_step(run, %{
        index: 0,
        title: "Approve me",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, reject_step} =
      Runtime.create_run_step(run, %{
        index: 1,
        title: "Reject me",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    view |> element("#control-approve-step-#{approve_step.id}") |> render_click()
    assert Runtime.get_run_step!(approve_step.id).status == "planned"

    view |> element("#control-reject-step-#{reject_step.id}") |> render_click()
    assert Runtime.get_run_step!(reject_step.id).status == "canceled"
  end
end
