defmodule HydraAgent.Runtime.RunnerTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.{Run, Runner, RunStep}
  alias HydraAgent.Safety

  describe "runnable state checks" do
    test "does not execute canceled runs" do
      assert {:error, %{"reason" => "run_not_runnable", "status" => "canceled"}} =
               Runner.execute_next_step(%Run{id: 1, status: "canceled"})
    end

    test "does not execute parallel batches for paused runs" do
      assert {:error, %{"reason" => "run_not_runnable", "status" => "paused"}} =
               Runner.execute_parallel_safe_batch(%Run{id: 1, status: "paused"})
    end

    test "does not lease steps for paused DB-backed runs" do
      %{agent: agent, run: run} = runtime_fixture()

      run_step_fixture(run, %{assigned_agent_id: agent.id})
      {:ok, paused_run} = Runtime.pause_run(run)

      assert {:error, %{"reason" => "run_not_runnable", "status" => "paused"}} =
               Runner.execute_next_step(paused_run, lease_owner: "paused-test")

      assert Runtime.step_status_counts(run.id) == %{"planned" => 1}
      assert event_types(run.id) == ["run.created", "step.planned", "run.paused"]
    end
  end

  describe "execute_next_step/2" do
    test "leases, authorizes, executes, and event-logs a read-only step" do
      %{agent: agent, run: run} = runtime_fixture()
      step = run_step_fixture(run, %{assigned_agent_id: agent.id, input: %{"hello" => "hydra"}})

      assert {:ok, completed_step} = Runner.execute_next_step(run, lease_owner: "worker-a")
      assert completed_step.id == step.id
      assert completed_step.status == "completed"
      assert completed_step.output == %{"input" => %{"hello" => "hydra"}}
      assert completed_step.lease_owner == nil
      assert completed_step.lease_expires_at == nil

      assert event_types(run.id) == [
               "run.created",
               "step.planned",
               "step.leased",
               "step.heartbeat",
               "step.started",
               "tool.authorized",
               "tool.executed",
               "step.completed"
             ]
    end

    test "moves dangerous authorized steps to approval and records safety event" do
      workspace = workspace_fixture()

      agent =
        agent_fixture(workspace, %{
          role: "builder",
          capability_profile: %{
            "role" => "builder",
            "tools" => ["knowledge_write"],
            "side_effect_classes" => ["workspace_write"],
            "max_autonomy_level" => "execute_with_approval"
          }
        })

      tool_policy_fixture(workspace, %{
        agent_id: agent.id,
        allowed_tools: ["knowledge_write"],
        side_effect_classes: ["workspace_write"],
        requires_approval: true
      })

      run =
        run_fixture(workspace, %{
          supervisor_agent_id: agent.id,
          autonomy_level: "execute_with_approval"
        })

      step =
        run_step_fixture(run, %{
          assigned_agent_id: agent.id,
          tool_name: "knowledge_write",
          side_effect_class: "workspace_write",
          input: %{"type_key" => "memory", "title" => "Learned thing"}
        })

      assert {:approval_required, awaiting_step} =
               Runner.execute_next_step(run, lease_owner: "approval-test")

      assert awaiting_step.id == step.id
      assert awaiting_step.status == "awaiting_approval"
      assert awaiting_step.lease_owner == nil
      assert Runtime.get_run!(run.id).status == "awaiting_approval"

      step_id = step.id

      assert [%{action: "tool_approval_required", run_step_id: ^step_id}] =
               Safety.list_events(workspace.id)

      assert "step.awaiting_approval" in event_types(run.id)
    end

    test "blocks unsafe steps and records policy safety event" do
      %{agent: agent, workspace: workspace, run: run} = runtime_fixture()

      step =
        run_step_fixture(run, %{
          assigned_agent_id: agent.id,
          tool_name: "knowledge_write",
          side_effect_class: "workspace_write"
        })

      assert {:blocked, blocked_step} = Runner.execute_next_step(run, lease_owner: "block-test")
      assert blocked_step.id == step.id
      assert blocked_step.status == "blocked"
      assert blocked_step.error["reason"] == "tool_not_in_agent_capabilities"

      step_id = step.id
      assert [%{action: "tool_blocked", run_step_id: ^step_id}] = Safety.list_events(workspace.id)
      assert "step.blocked" in event_types(run.id)
      assert "tool.blocked" in event_types(run.id)
    end

    test "fails step and run when a tool returns an error" do
      %{agent: agent, run: run} = runtime_fixture()

      step =
        run_step_fixture(run, %{
          assigned_agent_id: agent.id,
          tool_name: "knowledge_read",
          input: %{"id" => -1}
        })

      assert {:error, failed_step} = Runner.execute_next_step(run, lease_owner: "failure-test")
      assert failed_step.id == step.id
      assert failed_step.status == "failed"
      assert failed_step.error == %{"reason" => "node_not_found"}
      assert Runtime.get_run!(run.id).status == "failed"

      assert "step.failed" in event_types(run.id)
      assert "run.failed" in event_types(run.id)
    end
  end

  describe "leases and recovery" do
    test "does not double-lease an already running step" do
      %{agent: agent, run: run} = runtime_fixture()
      run_step_fixture(run, %{assigned_agent_id: agent.id})

      assert {:ok, %RunStep{status: "running"}} =
               Runtime.lease_next_step(run, "lease-owner-a", lease_ms: 60_000)

      assert {:ok, nil} = Runtime.lease_next_step(run, "lease-owner-b", lease_ms: 60_000)
      assert Runtime.step_status_counts(run.id) == %{"running" => 1}
    end

    test "recovers expired leases to planned before max attempts" do
      %{agent: agent, workspace: workspace, run: run} = runtime_fixture()

      step =
        run_step_fixture(run, %{
          assigned_agent_id: agent.id,
          status: "running",
          attempt_count: 1,
          lease_owner: "stale",
          lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert [%RunStep{id: step_id, status: "planned"}] =
               Runner.recover_workspace(workspace.id, max_attempts: 3)

      assert step_id == step.id
      recovered_step = Runtime.get_run_step!(step.id)
      assert recovered_step.lease_owner == nil
      assert recovered_step.lease_expires_at == nil
      assert "step.retrying" in event_types(run.id)
    end

    test "fails expired leases at max attempts" do
      %{agent: agent, workspace: workspace, run: run} = runtime_fixture()

      step =
        run_step_fixture(run, %{
          assigned_agent_id: agent.id,
          status: "running",
          attempt_count: 3,
          lease_owner: "stale",
          lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert [%RunStep{id: step_id, status: "failed"}] =
               Runner.recover_workspace(workspace.id, max_attempts: 3)

      assert step_id == step.id
      failed_step = Runtime.get_run_step!(step.id)
      assert failed_step.error["reason"] == "lease_expired"
      assert "step.failed" in event_types(run.id)
    end
  end

  defp event_types(run_id) do
    run_id
    |> Runtime.list_run_events()
    |> Enum.map(& &1.event_type)
  end
end
