defmodule HydraAgent.LoopsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Audit, Loops, Runtime, Usage}
  alias HydraAgent.Loops.Engine

  test "validates cron trigger and timezone fail closed" do
    workspace = workspace_fixture(%{slug: "loops-cron-validation"})
    agent = agent_fixture(workspace, %{slug: "loops-cron-agent", role: "supervisor"})

    assert {:error, changeset} =
             Loops.create_loop(%{
               workspace_id: workspace.id,
               supervisor_agent_id: agent.id,
               name: "Bad Cron",
               slug: "bad-cron",
               purpose: "Invalid schedule.",
               trigger: %{
                 "type" => "cron",
                 "cron_expression" => "not cron",
                 "timezone" => "Etc/UTC"
               }
             })

    assert %{trigger: [_message]} = errors_on(changeset)

    assert {:error, changeset} =
             Loops.create_loop(%{
               workspace_id: workspace.id,
               supervisor_agent_id: agent.id,
               name: "Bad Zone",
               slug: "bad-zone",
               purpose: "Invalid timezone.",
               trigger: %{
                 "type" => "cron",
                 "cron_expression" => "0 9 * * *",
                 "timezone" => "Not/AZone"
               }
             })

    assert %{trigger: [_message]} = errors_on(changeset)
  end

  test "manual tick creates a run and records a no-work stop reason" do
    workspace = workspace_fixture(%{slug: "loops-manual-tick"})
    agent = agent_fixture(workspace, %{slug: "loops-manual-agent", role: "supervisor"})
    loop = loop_fixture(workspace, %{supervisor_agent: agent})

    assert {:ok, result} =
             Engine.tick(loop,
               decision: %{
                 "action" => "no_work",
                 "summary" => "Nothing to do.",
                 "progress_fingerprint" => "empty",
                 "state_patch" => %{"cursor" => "checked"}
               }
             )

    assert result.stop_reason == "no_work"
    assert result.run.loop_id == loop.id
    assert result.run.status == "completed"
    assert result.loop.state["cursor"] == "checked"
    assert result.loop.metadata["last_stop_reason"] == "no_work"

    events = Runtime.list_run_events(result.run.id)
    assert Enum.any?(events, &(&1.event_type == "loop.tick.started"))
    assert Enum.any?(events, &(&1.event_type == "loop.tick.completed"))
  end

  test "dispatch decision creates delegated child runs with loop lineage" do
    workspace = workspace_fixture(%{slug: "loops-dispatch"})
    agent = agent_fixture(workspace, %{slug: "loops-dispatch-agent", role: "supervisor"})
    loop = loop_fixture(workspace, %{supervisor_agent: agent})

    assert {:ok, result} =
             Engine.tick(loop,
               decision: %{
                 "action" => "dispatch_runs",
                 "summary" => "Dispatch review.",
                 "progress_fingerprint" => "one-child",
                 "state_patch" => %{"dispatched" => true},
                 "delegated_runs" => [
                   %{"title" => "Review runtime", "goal" => "Inspect the runtime queue."}
                 ]
               }
             )

    assert [%{loop_id: loop_id, parent_run_id: parent_run_id, lineage_type: "delegated"}] =
             result.child_runs

    assert loop_id == loop.id
    assert parent_run_id == result.run.id
  end

  test "repeated no-progress blocks the loop and tick run" do
    workspace = workspace_fixture(%{slug: "loops-no-progress"})
    agent = agent_fixture(workspace, %{slug: "loops-no-progress-agent", role: "supervisor"})

    loop =
      loop_fixture(workspace, %{
        supervisor_agent: agent,
        state: %{"last_progress_fingerprint" => "same", "consecutive_no_progress" => 0},
        guardrails: %{
          "max_iterations_per_tick" => 1,
          "max_child_runs_per_tick" => 3,
          "max_consecutive_no_progress" => 1,
          "max_runtime_seconds" => 300
        }
      })

    assert {:ok, result} =
             Engine.tick(loop,
               decision: %{
                 "action" => "dispatch_runs",
                 "summary" => "Still stuck.",
                 "progress_fingerprint" => "same",
                 "state_patch" => %{},
                 "delegated_runs" => []
               }
             )

    assert result.stop_reason == "no_progress"
    assert result.loop.status == "blocked"
    assert result.run.status == "blocked"
    assert result.loop.last_error["reason"] == "no_progress"
  end

  test "budget guardrail blocks provider spend before tick run creation" do
    workspace = workspace_fixture(%{slug: "loops-budget"})
    agent = agent_fixture(workspace, %{slug: "loops-budget-agent", role: "supervisor"})
    loop = loop_fixture(workspace, %{supervisor_agent: agent, guardrails: %{"token_limit" => 1}})

    run = run_fixture(workspace, %{loop_id: loop.id, supervisor_agent_id: agent.id})

    {:ok, _record} =
      Usage.create_record(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        run_id: run.id,
        category: "loop",
        status: "ok",
        total_tokens: 1
      })

    assert {:error, %{"reason" => "budget_exceeded"}} =
             Engine.tick(loop,
               decision: %{
                 "action" => "no_work",
                 "summary" => "Should not run.",
                 "state_patch" => %{}
               }
             )

    assert Loops.get_loop!(loop.id).status == "blocked"
  end

  test "worker scans only due active loops and respects leases" do
    workspace = workspace_fixture(%{slug: "loops-worker"})
    agent = agent_fixture(workspace, %{slug: "loops-worker-agent", role: "supervisor"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    due =
      loop_fixture(workspace, %{
        supervisor_agent: agent,
        trigger: %{"type" => "cron", "cron_expression" => "* * * * *", "timezone" => "Etc/UTC"},
        next_tick_at: DateTime.add(now, -60, :second)
      })

    _future =
      loop_fixture(workspace, %{
        supervisor_agent: agent,
        slug: "future-loop",
        trigger: %{"type" => "cron", "cron_expression" => "* * * * *", "timezone" => "Etc/UTC"},
        next_tick_at: DateTime.add(now, 60, :second)
      })

    assert [found] = Loops.due_loops(now)
    assert found.id == due.id

    assert {:ok, leased} = Loops.acquire_lease(due, "test-owner", now, 60_000)

    assert {:error, %{"reason" => "lease_conflict"}} =
             Loops.acquire_lease(leased, "other", now, 60_000)
  end

  test "audit and run trace include loop lineage" do
    workspace = workspace_fixture(%{slug: "loops-audit-trace"})
    agent = agent_fixture(workspace, %{slug: "loops-audit-agent", role: "supervisor"})
    loop = loop_fixture(workspace, %{supervisor_agent: agent})

    {:ok, result} =
      Engine.tick(loop,
        decision: %{
          "action" => "no_work",
          "summary" => "Audited.",
          "progress_fingerprint" => "audit",
          "state_patch" => %{}
        }
      )

    audit = Audit.export_workspace(workspace.id)
    assert [%{"id" => loop_id}] = audit["loops"]
    assert loop_id == loop.id
    assert Enum.any?(audit["runs"], &(&1["loop_id"] == loop.id))

    trace = Runtime.trace_run(result.run.id)
    assert trace.loop.id == loop.id
    assert trace.run.loop_id == loop.id
  end
end
