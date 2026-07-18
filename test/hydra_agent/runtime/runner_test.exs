defmodule HydraAgent.Runtime.RunnerTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime
  alias HydraAgent.Runtime.{Run, Runner, RunStep}
  alias HydraAgent.Safety
  alias HydraAgent.Tools.FileRead

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
      assert Runtime.get_run!(run.id).status == "blocked"

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

    test "run metadata cannot replace the trusted workspace root" do
      root =
        Path.join(
          System.tmp_dir!(),
          "hydra-runner-root-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      File.write!(Path.join(root, "environ"), "workspace-safe-value")
      on_exit(fn -> File.rm_rf(root) end)

      workspace = workspace_fixture(%{settings: %{"project_root" => root}})
      agent = agent_fixture(workspace)
      tool_policy_fixture(workspace, %{agent_id: agent.id})

      run =
        run_fixture(workspace, %{
          supervisor_agent_id: agent.id,
          metadata: %{"workspace_root" => "/proc/self", "request_id" => "kept"}
        })

      assert run.metadata == %{"request_id" => "kept"}

      legacy_run =
        run
        |> Ecto.Changeset.change(metadata: %{"workspace_root" => "/proc/self"})
        |> Repo.update!()

      run_step_fixture(legacy_run, %{assigned_agent_id: agent.id})

      executor = fn _tool_name, _input, context ->
        FileRead.execute(%{"path" => "environ"}, context)
      end

      assert {:ok, %RunStep{output: output}} =
               Runner.execute_next_step(legacy_run,
                 lease_owner: "workspace-root-test",
                 executor: executor
               )

      assert output["content"] == "workspace-safe-value"
      refute output["content"] =~ "PATH="
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

    test "leases sequential steps in order even under concurrent callers" do
      %{agent: agent, run: run} = runtime_fixture()
      first = run_step_fixture(run, %{index: 0, title: "First", assigned_agent_id: agent.id})
      second = run_step_fixture(run, %{index: 1, title: "Second", assigned_agent_id: agent.id})

      first_lease =
        Task.async(fn -> Runtime.lease_next_step(run, "worker-a", lease_ms: 60_000) end)

      second_lease =
        Task.async(fn -> Runtime.lease_next_step(run, "worker-b", lease_ms: 60_000) end)

      results = [Task.await(first_lease), Task.await(second_lease)]
      assert Enum.count(results, &match?({:ok, %RunStep{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:ok, nil})) == 1

      leased =
        Enum.find_value(results, fn
          {:ok, %RunStep{} = step} -> step
          _ -> nil
        end)

      assert leased.id == first.id

      assert {:ok, _completed} =
               Runtime.release_step_lease(leased, %{
                 "status" => "completed",
                 "completed_at" => DateTime.utc_now()
               })

      assert {:ok, %RunStep{id: second_id}} =
               Runtime.lease_next_step(run, "worker-b", lease_ms: 60_000)

      assert second_id == second.id
    end

    test "an earlier non-terminal step blocks later planned work" do
      %{agent: agent, run: run} = runtime_fixture()

      run_step_fixture(run, %{
        index: 0,
        status: "awaiting_approval",
        title: "Needs approval",
        assigned_agent_id: agent.id
      })

      run_step_fixture(run, %{index: 1, title: "Later", assigned_agent_id: agent.id})

      assert {:ok, nil} = Runtime.lease_next_step(run, "worker-a", lease_ms: 60_000)
      assert Runtime.step_status_counts(run.id) == %{"awaiting_approval" => 1, "planned" => 1}
    end

    test "renews the lease throughout a long-running tool" do
      %{agent: agent, run: run} = runtime_fixture()
      run_step_fixture(run, %{assigned_agent_id: agent.id})

      slow_executor = fn _tool_name, input, _context ->
        Process.sleep(180)
        {:ok, %{"input" => input}}
      end

      assert {:ok, %RunStep{status: "completed"}} =
               Runner.execute_next_step(run,
                 lease_owner: "slow-worker",
                 lease_ms: 90,
                 heartbeat_interval_ms: 20,
                 executor: slow_executor
               )

      heartbeat_count =
        run.id
        |> Runtime.list_run_events()
        |> Enum.count(&(&1.event_type == "step.heartbeat"))

      assert heartbeat_count >= 3
    end

    test "a recovered lease fences a late original completion" do
      %{agent: agent, workspace: workspace, run: run} = runtime_fixture()
      run_step_fixture(run, %{assigned_agent_id: agent.id})

      assert {:ok, original} = Runtime.lease_next_step(run, "original", lease_ms: 50)
      Process.sleep(70)

      assert [%RunStep{status: "planned"}] =
               Runtime.recover_stale_steps(workspace.id, max_attempts: 3)

      assert {:ok, replacement} = Runtime.lease_next_step(run, "replacement", lease_ms: 60_000)

      assert {:error, :lease_lost} =
               Runtime.release_step_lease(original, %{
                 "status" => "completed",
                 "completed_at" => DateTime.utc_now()
               })

      assert Runtime.get_run_step!(replacement.id).lease_owner == "replacement"
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
      assert Runtime.get_run!(run.id).status == "failed"
    end
  end

  describe "state transition guards" do
    test "terminal runs cannot be restarted" do
      %{run: run} = runtime_fixture()
      assert {:ok, completed} = Runtime.complete_run(run)

      assert {:error, {:invalid_run_transition, "completed", "running"}} =
               Runtime.start_run(completed)

      assert Runtime.get_run!(run.id).status == "completed"
    end

    test "only approval-pending steps can be approved" do
      %{agent: agent, run: run} = runtime_fixture()
      step = run_step_fixture(run, %{assigned_agent_id: agent.id, status: "completed"})

      assert {:error, {:invalid_step_transition, "completed", "planned"}} =
               Runtime.approve_run_step(step)

      assert Runtime.get_run_step!(step.id).status == "completed"
    end
  end

  defp event_types(run_id) do
    run_id
    |> Runtime.list_run_events()
    |> Enum.map(& &1.event_type)
  end
end
