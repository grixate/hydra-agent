defmodule HydraAgentWeb.RunDetailLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.{Memory, Runtime, Skills}
  alias HydraAgent.Safety

  test "renders a run detail timeline from durable runtime and safety events", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail"})
    run = run_fixture(workspace, %{title: "Inspect runtime", goal: "Show the evidence trail"})

    step =
      run_step_fixture(run, %{
        index: 0,
        title: "Read state",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })

    {:ok, _event} =
      Safety.record_event(%{
        workspace_id: workspace.id,
        run_id: run.id,
        run_step_id: step.id,
        category: "runtime",
        severity: "info",
        action: "operator_note",
        summary: "Operator added note",
        metadata: %{"source" => "test"}
      })

    {:ok, view, html} = live(conn, ~p"/control/runs/#{run.id}")

    assert html =~ "Inspect runtime"
    assert has_element?(view, "#run-detail")
    assert has_element?(view, "#run-detail-steps")
    assert has_element?(view, "#run-detail-timeline")
    assert render(view) =~ "run.created"
    assert render(view) =~ "step.planned"
    assert render(view) =~ "operator_note"
    assert render(view) =~ "Read state"
  end

  test "run detail controls update durable run state", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail-actions"})
    run = run_fixture(workspace, %{title: "Control action", goal: "Exercise detail controls"})

    {:ok, view, _html} = live(conn, ~p"/control/runs/#{run.id}")

    view |> element("#run-detail-start-run") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#run-detail-pause-run") |> render_click()
    assert Runtime.get_run!(run.id).status == "paused"

    view |> element("#run-detail-resume-run") |> render_click()
    assert Runtime.get_run!(run.id).status == "running"

    view |> element("#run-detail-cancel-run") |> render_click()
    assert Runtime.get_run!(run.id).status == "canceled"
  end

  test "run detail approval controls update awaiting steps", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail-approvals"})
    run = run_fixture(workspace, %{title: "Approval detail", goal: "Exercise approvals"})

    approve_step =
      run_step_fixture(run, %{
        index: 0,
        title: "Approve detail",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    reject_step =
      run_step_fixture(run, %{
        index: 1,
        title: "Reject detail",
        status: "awaiting_approval",
        tool_name: "knowledge_write",
        side_effect_class: "workspace_write"
      })

    {:ok, view, _html} = live(conn, ~p"/control/runs/#{run.id}")

    view |> element("#run-detail-approve-step-#{approve_step.id}") |> render_click()
    assert Runtime.get_run_step!(approve_step.id).status == "planned"

    view |> element("#run-detail-reject-step-#{reject_step.id}") |> render_click()
    assert Runtime.get_run_step!(reject_step.id).status == "canceled"
  end

  test "run detail can draft a proposed skill from the run", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail-skill"})
    agent = agent_fixture(workspace, %{name: "Skill Author", slug: "skill-author"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Extract Review Procedure",
        goal: "Turn this run into a proposed skill."
      })

    _step =
      run_step_fixture(run, %{
        index: 0,
        title: "Read evidence",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })

    {:ok, view, _html} = live(conn, ~p"/control/runs/#{run.id}")

    view |> element("#run-detail-draft-skill") |> render_click()

    [skill] = Skills.list_skills(workspace.id)
    assert skill.status == "proposed"
    assert skill.owner_agent_id == agent.id
    assert skill.source_run_id == run.id
    assert skill.instructions =~ "Read evidence"

    assert_redirect(view, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")
  end

  test "run detail can draft a memory proposal from the run", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail-memory"})
    agent = agent_fixture(workspace, %{name: "Memory Author", slug: "memory-author"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Capture Runtime Lesson",
        goal: "Turn this run into a pending memory."
      })

    _step =
      run_step_fixture(run, %{
        index: 0,
        title: "Inspect timeline",
        status: "completed",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })

    {:ok, view, _html} = live(conn, ~p"/control/runs/#{run.id}")

    view |> element("#run-detail-draft-memory") |> render_click()

    [proposal] = Memory.list_proposals(workspace.id)
    assert proposal.status == "draft"
    assert proposal.created_by_agent_id == agent.id
    assert proposal.provenance["source"] == "run_detail"
    assert proposal.provenance["run_id"] == run.id
    assert proposal.body =~ "Inspect timeline: completed"

    assert_redirect(view, ~p"/control/memory?workspace_id=#{workspace.id}")
  end

  test "control overview links to the run detail timeline", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-run-detail-link"})
    run = run_fixture(workspace, %{title: "Linked run", goal: "Open the detail view"})

    {:ok, view, _html} = live(conn, ~p"/control?workspace_id=#{workspace.id}")

    assert has_element?(view, ~s|a[href="/control/runs/#{run.id}"]|, "Open timeline")
  end
end
