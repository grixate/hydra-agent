defmodule HydraAgent.Agent.SupervisorTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Agent.Supervisor, as: AgentSupervisor
  alias HydraAgent.Runtime

  test "run_worker_status returns inactive run summary when no worker is running" do
    %{agent: agent, run: run} = runtime_fixture()
    run_step_fixture(run, %{assigned_agent_id: agent.id})

    assert %{
             active: false,
             pid: nil,
             run_id: run_id,
             run_status: "planned",
             current_step_id: nil,
             step_counts: %{"planned" => 1}
           } = AgentSupervisor.run_worker_status(run.id)

    assert run_id == run.id
  end

  test "run_worker_status reports current running step from durable state" do
    %{agent: agent, run: run} = runtime_fixture()

    step =
      run_step_fixture(run, %{
        assigned_agent_id: agent.id,
        status: "running",
        lease_owner: "manual-worker",
        heartbeat_at: DateTime.utc_now()
      })

    assert %{
             active: false,
             current_step_id: step_id,
             current_step_title: "Test Step",
             current_step_status: "running",
             step_counts: %{"running" => 1}
           } = AgentSupervisor.run_worker_status(run.id)

    assert step_id == step.id
  end

  test "run worker operations normalize string run ids" do
    %{run: run} = runtime_fixture()

    assert %{active: false, run_id: run_id} = AgentSupervisor.run_worker_status(to_string(run.id))
    assert run_id == run.id
    assert {:error, :not_found} = AgentSupervisor.stop_run_worker(to_string(run.id))
  end

  test "started worker can be introspected and stops without failing the run" do
    %{agent: agent, run: run} = runtime_fixture()
    run_step_fixture(run, %{assigned_agent_id: agent.id})

    assert {:ok, _pid} =
             AgentSupervisor.start_run_worker(run.id, auto_complete?: false, lease_ms: 60_000)

    assert_eventually(fn ->
      status = AgentSupervisor.run_worker_status(run.id)
      assert status.run_id == run.id
      assert is_map(status.step_counts)
    end)

    assert AgentSupervisor.stop_run_worker(run.id) in [:ok, {:error, :not_found}]
    refute Runtime.get_run!(run.id).status == "failed"
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 0), do: fun.()
end
