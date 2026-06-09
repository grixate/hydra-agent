defmodule HydraAgent.SimulationTest do
  use HydraAgent.DataCase, async: false

  import ExUnit.CaptureLog
  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Simulation.Agent.Persona
  alias HydraAgent.Simulation.Engine.{BatchInference, DecisionRouter, Runner}
  alias HydraAgent.Simulation.Simulation, as: SimulationRecord
  alias HydraAgent.Simulation.World.Event
  alias HydraAgent.Tools.Registry
  alias HydraAgent.{Budgets, Safety, Simulation}

  describe "create_simulation/1" do
    test "creates a workspace-scoped simulation with generated personas and budget estimate" do
      workspace = workspace_fixture()
      agent = agent_fixture(workspace)

      assert {:ok, simulation} =
               Simulation.create_simulation(%{
                 workspace_id: workspace.id,
                 supervisor_agent_id: agent.id,
                 title: "Adoption rehearsal",
                 goal: "Explore how a mixed stakeholder group reacts to a rollout.",
                 config: %{"agent_count" => 5, "max_ticks" => 4, "max_budget_cents" => 50}
               })

      assert simulation.workspace_id == workspace.id
      assert simulation.status == "configuring"
      assert simulation.budget_plan["estimated_decisions"] == 20
      assert simulation.budget_reservation.status == "active"

      assert simulation.budget_reservation.reserved_cost_cents >=
               simulation.budget_plan["estimated_cost_cents"]

      assert length(simulation.agent_profiles) == 5
    end

    test "blocks creation when the preflight estimate exceeds the hard cap" do
      workspace = workspace_fixture()

      assert {:error, %{"reason" => "estimated_budget_exceeded"}} =
               Simulation.create_simulation(%{
                 workspace_id: workspace.id,
                 title: "Too broad",
                 goal: "This should exceed the configured simulation budget.",
                 config: %{
                   "agent_count" => 1_000,
                   "max_ticks" => 1_000,
                   "max_budget_cents" => 1,
                   "frontier_cost_per_million_tokens" => 30.0
                 }
               })
    end

    test "blocks creation when projected simulation usage would exceed an active budget" do
      workspace = workspace_fixture()

      {:ok, _budget} =
        Budgets.create_budget(%{
          workspace_id: workspace.id,
          name: "Tiny simulation token cap",
          category: "simulation",
          period: "monthly",
          token_limit: 1
        })

      assert {:error, %{"reason" => "budget_exceeded", "category" => "simulation"}} =
               Simulation.create_simulation(%{
                 workspace_id: workspace.id,
                 title: "Budget gated",
                 goal: "This run should be blocked before any rows are inserted.",
                 config: %{"agent_count" => 2, "max_ticks" => 2, "max_budget_cents" => 1_000}
               })
    end

    test "active simulation reservations count against workspace cost budgets" do
      workspace = workspace_fixture()

      {:ok, _budget} =
        Budgets.create_budget(%{
          workspace_id: workspace.id,
          name: "Tiny simulation cost cap",
          category: "simulation",
          period: "monthly",
          cost_limit: Decimal.new("0.30")
        })

      assert {:ok, _simulation} =
               Simulation.create_simulation(%{
                 workspace_id: workspace.id,
                 title: "First reserved run",
                 goal: "Reserve most of the budget.",
                 config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
               })

      assert {:error, %{"reason" => "budget_exceeded", "category" => "simulation"}} =
               Simulation.create_simulation(%{
                 workspace_id: workspace.id,
                 title: "Second reserved run",
                 goal: "Should see the active reservation.",
                 config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
               })
    end

    test "lists simulations with query filtering and pagination" do
      workspace = workspace_fixture()

      {:ok, alpha} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Alpha rollout",
          goal: "Find launch risks.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      {:ok, _beta} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Beta incident",
          goal: "Exercise support response.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert [%{id: id}] = Simulation.list_simulations(workspace.id, query: "rollout")
      assert id == alpha.id
      assert [_one] = Simulation.list_simulations(workspace.id, limit: "1", offset: "1")
    end
  end

  describe "run_to_completion/2" do
    test "runs ticks durably and generates replayable reports without a provider route" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Deterministic simulation",
          goal: "Exercise the simulation runner without external LLM calls.",
          config: %{
            "agent_count" => 3,
            "max_ticks" => 3,
            "max_budget_cents" => 20,
            "event_frequency" => 1.0,
            "crisis_probability" => 0.0,
            "rng_seed" => 42
          }
        })

      assert {:ok, completed} = Simulation.run_to_completion(simulation)
      assert completed.status == "completed"
      assert completed.total_ticks == 3
      assert length(completed.ticks) == 3
      assert completed.total_cost_cents == 0
      assert completed.budget_reservation.status == "released"
      assert completed.world_snapshot["tick_summary"]["tick"] == 2

      assert {:ok, report} = Simulation.generate_report(completed)
      assert report.content =~ "Deterministic simulation"
      assert report.statistical_summary["key_outcomes"] != []

      replay = Simulation.replay(completed)
      assert replay["simulation"].id == completed.id
      assert length(replay["ticks"]) == 3
      assert Enum.any?(replay["events"], &(&1.event_type == "agent_action"))

      filtered =
        Simulation.replay(completed, %{"event_type" => "agent_action", "tick_from" => "1"})

      assert Enum.all?(filtered["events"], &(&1.event_type == "agent_action" and &1.tick >= 1))

      export = Simulation.export(completed)
      assert export["budget_reservation"].status == "released"
      assert length(export["agent_profiles"]) == 3
    end

    test "same seed and config produce deterministic replayable events" do
      workspace = workspace_fixture()

      config = %{
        "agent_count" => 3,
        "max_ticks" => 3,
        "max_budget_cents" => 100,
        "event_frequency" => 1.0,
        "crisis_probability" => 0.0,
        "rng_seed" => 123
      }

      {:ok, first} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Seeded run A",
          goal: "Check deterministic replay.",
          config: config
        })

      {:ok, second} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Seeded run B",
          goal: "Check deterministic replay.",
          config: config
        })

      assert {:ok, first} = Simulation.run_to_completion(first)
      assert {:ok, second} = Simulation.run_to_completion(second)

      assert replay_signature(first) == replay_signature(second)
    end

    test "persists downgrade and skipped LLM counters in budget usage" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Counter run",
          goal: "Persist budget-aware downgrade counters.",
          config: %{
            "agent_count" => 2,
            "max_ticks" => 1,
            "max_budget_cents" => 100,
            "event_frequency" => 1.0,
            "crisis_probability" => 0.0,
            "stakes_threshold" => 0.0,
            "max_llm_calls" => 1,
            "personas" => [
              %{"name" => "Morgan", "role" => "Operator", "traits" => %{}},
              %{"name" => "Riley", "role" => "Analyst", "traits" => %{}}
            ]
          }
        })

      assert {:ok, completed} = Simulation.run_to_completion(simulation)
      assert completed.budget_usage["downgraded_count"] == 1
      assert completed.budget_usage["skipped_llm_count"] == 1
      assert completed.world_snapshot["tick_summary"]["skipped_llm_count"] == 1
    end

    test "blocks after actual provider cost exceeds remaining simulation budget" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Actual cost guard",
          goal: "Stop after actual provider usage exceeds the hard cap.",
          config: %{
            "agent_count" => 1,
            "max_ticks" => 1,
            "max_budget_cents" => 1,
            "event_frequency" => 1.0,
            "crisis_probability" => 0.0,
            "stakes_threshold" => 0.0,
            "cheap_tokens_per_call" => 1,
            "cheap_cost_per_million_tokens" => 1.0,
            "complex_share" => 0.01,
            "negotiation_share" => 0.0,
            "personas" => [%{"name" => "Morgan", "role" => "Operator", "traits" => %{}}]
          }
        })

      llm_fn = fn _request ->
        {:ok,
         %{
           "content" => ~s({"action":"wait_and_observe","reasoning":"large actual usage"}),
           "usage" => %{"total_tokens" => 2_000_000}
         }}
      end

      assert {:ok, blocked} = Simulation.run_to_completion(simulation, llm_fn: llm_fn)
      assert blocked.status == "budget_blocked"

      assert blocked.budget_usage["blocked_reason"] ==
               "actual_provider_cost_exceeded_simulation_budget"

      assert blocked.total_cost_cents > blocked.config["max_budget_cents"]
      assert blocked.budget_reservation.status == "exhausted"
    end

    test "tick recording is idempotent for duplicate tick numbers" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Idempotent tick",
          goal: "Avoid double counting duplicate execution attempts.",
          config: %{"agent_count" => 1, "max_ticks" => 2, "max_budget_cents" => 20}
        })

      assert {:ok, first} =
               Simulation.record_tick(simulation, %{
                 "tick_number" => 0,
                 "llm_calls" => 1,
                 "tokens_used" => 10,
                 "cost_cents" => 2,
                 "world_delta" => %{"tick" => 0}
               })

      assert {:ok, duplicate} =
               Simulation.record_tick(simulation, %{
                 "tick_number" => 0,
                 "llm_calls" => 1,
                 "tokens_used" => 10,
                 "cost_cents" => 2,
                 "world_delta" => %{"tick" => 0}
               })

      updated = Simulation.get_simulation!(simulation.id)
      assert duplicate.id == first.id
      assert updated.total_ticks == 1
      assert updated.total_cost_cents == 2
    end

    test "terminal simulations reject new tick records" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Terminal tick guard",
          goal: "Do not mutate terminal simulations.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, running} = Simulation.start_simulation(simulation, async: false)
      assert {:ok, canceled} = Simulation.cancel_simulation(running)

      assert {:error, %{"reason" => "simulation_terminal", "status" => "canceled"}} =
               Simulation.record_tick(canceled, %{
                 "tick_number" => 0,
                 "llm_calls" => 1,
                 "tokens_used" => 10,
                 "cost_cents" => 2,
                 "world_delta" => %{"tick" => 0}
               })

      refute Repo.get_by(HydraAgent.Simulation.Tick, simulation_id: simulation.id, tick_number: 0)
    end
  end

  describe "start_simulation/2" do
    test "runs under a supervised worker and exposes worker status" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Async rehearsal",
          goal: "Keep a worker alive long enough to inspect it.",
          config: %{
            "agent_count" => 2,
            "max_ticks" => 8,
            "max_budget_cents" => 20,
            "tick_interval_ms" => 50,
            "event_frequency" => 1.0,
            "rng_seed" => 7
          }
        })

      runner_fn = fn _simulation_id, _opts ->
        Process.sleep(200)
        {:ok, :stubbed}
      end

      assert {:ok, running} = Simulation.start_simulation(simulation, runner_fn: runner_fn)
      assert %{active: true, task_pid: task_pid} = wait_for_worker(running)
      assert is_binary(task_pid)

      assert {:ok, canceled} = Simulation.cancel_simulation(running)
      assert canceled.status == "canceled"
      assert %{active: false} = wait_for_worker_stop(canceled)
    end

    test "terminal simulations cannot be paused, canceled again, or failed by stale workers" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Terminal state guard",
          goal: "Keep final simulation states immutable.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, completed} = Simulation.run_to_completion(simulation)
      stale_running = %{completed | status: "running"}

      assert {:error, %{"reason" => "simulation_not_pausable", "status" => "completed"}} =
               Simulation.pause_simulation(stale_running)

      assert {:error, %{"reason" => "simulation_not_cancelable", "status" => "completed"}} =
               Simulation.cancel_simulation(stale_running)

      assert {:error,
              %{
                "reason" => "simulation_transition_not_allowed",
                "status" => "completed",
                "target_status" => "failed"
              }} = Simulation.fail_simulation(stale_running, :late_worker_error)

      assert Simulation.get_simulation!(simulation.id).status == "completed"
    end

    test "marks the simulation failed when the supervised runner crashes" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Crash rehearsal",
          goal: "Make runner failure durable.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      runner_fn = fn _simulation_id, _opts -> raise "boom" end

      test_pid = self()

      capture_log(fn ->
        assert {:ok, running} = Simulation.start_simulation(simulation, runner_fn: runner_fn)
        assert %{active: false} = wait_for_worker_stop(running)
        send(test_pid, {:running, running})
      end)

      assert_receive {:running, running}

      failed = Simulation.get_simulation!(running.id)

      assert failed.status == "failed"
      assert failed.budget_usage["error"] =~ "boom"
    end

    test "recovers expired running simulations with no active worker" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Recover me",
          goal: "Restart after a stale lease.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      {:ok, running} =
        simulation
        |> SimulationRecord.changeset(%{
          "status" => "running",
          "lease_id" => "stale",
          "lease_expires_at" => past,
          "last_heartbeat_at" => past
        })
        |> Repo.update()

      assert [{:ok, recovered}] = Simulation.recover_running_simulations(limit: 1)
      assert recovered.status in ["running", "completed"]

      eventually = wait_for_worker_stop(running)
      assert eventually.active == false

      recovered = Simulation.get_simulation!(running.id)
      assert recovered.recovery_count == 1
    end

    test "heartbeats extend only the current lease" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Heartbeat lease",
          goal: "Keep the active worker lease current.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, running} = Simulation.start_simulation(simulation, async: false)
      assert :ok = Simulation.heartbeat_simulation(running.id, running.lease_id)
      assert {:error, :lease_not_current} = Simulation.heartbeat_simulation(running.id, "stale")

      heartbeated = Simulation.get_simulation!(running.id)

      assert DateTime.compare(heartbeated.lease_expires_at, running.lease_expires_at) in [
               :gt,
               :eq
             ]
    end

    test "blocks starts beyond the workspace concurrent simulation limit" do
      previous = Application.get_env(:hydra_agent, :max_concurrent_simulations)
      Application.put_env(:hydra_agent, :max_concurrent_simulations, 1)

      on_exit(fn ->
        if previous do
          Application.put_env(:hydra_agent, :max_concurrent_simulations, previous)
        else
          Application.delete_env(:hydra_agent, :max_concurrent_simulations)
        end
      end)

      workspace = workspace_fixture()

      {:ok, first} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "First concurrent",
          goal: "Occupy the running slot.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      {:ok, second} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Second concurrent",
          goal: "Should be blocked by concurrency.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, running} = Simulation.start_simulation(first, async: false)

      assert {:error,
              %{
                "reason" => "simulation_concurrency_limit_exceeded",
                "max_concurrent_simulations" => 1
              }} = Simulation.start_simulation(second, async: false)

      assert {:ok, _canceled} = Simulation.cancel_simulation(running)
    end

    test "fails simulations that exceed configured wall-clock duration" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Wall clock guard",
          goal: "Stop overdue simulations.",
          config: %{
            "agent_count" => 1,
            "max_ticks" => 2,
            "max_budget_cents" => 20,
            "max_wall_clock_seconds" => 1
          }
        })

      {:ok, running} = Simulation.start_simulation(simulation, async: false)
      past = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:microsecond)

      {:ok, overdue} =
        running
        |> SimulationRecord.changeset(%{"started_at" => past})
        |> Repo.update()

      assert {:ok, failed} = Runner.run(overdue.id)
      assert failed.status == "failed"
      assert failed.budget_usage["error"] =~ "max_wall_clock_exceeded"
    end
  end

  describe "BatchInference.run/5" do
    test "downgrades over-budget LLM requests before dispatch" do
      config =
        HydraAgent.Simulation.Config.normalize(%{
          "cheap_tokens_per_call" => 8_000,
          "cheap_cost_per_million_tokens" => 50.0
        })

      persona = Persona.new(%{"name" => "Morgan", "role" => "Operator"})
      event = Event.generate(0, Map.put(config, "event_frequency", 1.0)) |> hd()

      request = %{
        persona: persona,
        event: event,
        state: %{},
        tier: :cheap,
        messages: [],
        agent_key: "morgan",
        profile_id: 123
      }

      result = BatchInference.run([request], %{workspace_id: 1}, config, 0)

      assert result.llm_calls == 0
      assert result.cost_cents == 0
      assert result.downgraded_count == 1
      assert result.skipped_llm_count == 1
      assert [%{"method" => "rules_engine", "downgraded_from" => "cheap"}] = result.results
    end

    test "flags batches where actual provider usage exceeds the remaining budget" do
      config =
        HydraAgent.Simulation.Config.normalize(%{
          "cheap_tokens_per_call" => 1,
          "cheap_cost_per_million_tokens" => 1.0
        })

      persona = Persona.new(%{"name" => "Morgan", "role" => "Operator"})
      event = Event.generate(0, Map.put(config, "event_frequency", 1.0)) |> hd()

      request = %{
        persona: persona,
        event: event,
        state: %{},
        tier: :cheap,
        messages: [],
        agent_key: "morgan",
        profile_id: 123
      }

      llm_fn = fn _request ->
        {:ok,
         %{
           "content" => ~s({"action":"wait_and_observe","reasoning":"large actual usage"}),
           "usage" => %{"total_tokens" => 2_000_000}
         }}
      end

      result = BatchInference.run([request], %{workspace_id: 1}, config, 1, llm_fn: llm_fn)

      assert result.llm_calls == 1
      assert result.cost_cents > 1
      assert result.budget_exceeded?
    end

    test "downgrades LLM requests beyond the configured call cap" do
      config =
        HydraAgent.Simulation.Config.normalize(%{
          "max_llm_calls" => 0,
          "cheap_tokens_per_call" => 1
        })

      persona = Persona.new(%{"name" => "Morgan", "role" => "Operator"})
      event = Event.generate(0, Map.put(config, "event_frequency", 1.0)) |> hd()

      request = %{
        persona: persona,
        event: event,
        state: %{},
        tier: :cheap,
        messages: [],
        agent_key: "morgan",
        profile_id: 123
      }

      result = BatchInference.run([request], %{workspace_id: 1}, config, 100)

      assert result.llm_calls == 0
      assert result.skipped_llm_count == 1
      assert [%{"downgraded_from" => "cheap"}] = result.results
    end

    test "downgrades LLM requests beyond the configured per-agent cost cap" do
      config =
        HydraAgent.Simulation.Config.normalize(%{
          "max_agent_cost_cents" => 50,
          "cheap_tokens_per_call" => 1_000_000,
          "cheap_cost_per_million_tokens" => 1.0
        })

      persona = Persona.new(%{"name" => "Morgan", "role" => "Operator"})
      event = Event.generate(0, Map.put(config, "event_frequency", 1.0)) |> hd()

      request = %{
        persona: persona,
        event: event,
        state: %{},
        tier: :cheap,
        messages: [],
        agent_key: "morgan",
        profile_id: 123,
        current_cost_cents: 0
      }

      result = BatchInference.run([request], %{workspace_id: 1}, config, 1_000)

      assert result.llm_calls == 0
      assert result.skipped_llm_count == 1
      assert [%{"downgraded_from" => "cheap"}] = result.results
    end
  end

  describe "DecisionRouter.classify/3" do
    test "uses persisted string category keys when checking novelty" do
      persona = Persona.new(%{"name" => "Morgan", "role" => "Operator", "traits" => %{}})
      event = Event.new(%{type: :market_shift, stakes: 1.0})

      state = %{
        seen_categories: %{"neutral" => 2},
        novelty_threshold: 2,
        stakes_threshold: 0.0,
        recent_negotiation?: false
      }

      assert DecisionRouter.classify(persona, event, state) == :routine
    end
  end

  describe "generate_report/1" do
    test "rejects non-terminal simulations" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Not done yet",
          goal: "Reports should wait for terminal states.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:error, %{"reason" => "simulation_not_reportable", "status" => "configuring"}} =
               Simulation.generate_report(simulation)
    end
  end

  describe "duplicate_simulation/2" do
    test "creates a fresh configurable copy and records duplicate audit metadata" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Source",
          goal: "Duplicate me.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, copy} = Simulation.duplicate_simulation(simulation, %{"title" => "Copy"})
      assert copy.status == "configuring"
      assert copy.title == "Copy"
      assert copy.id != simulation.id

      assert Enum.any?(Safety.list_events(workspace.id, category: "runtime"), fn event ->
               event.action == "simulation.duplicate" and
                 event.metadata["source_simulation_id"] == simulation.id
             end)
    end
  end

  describe "budget categories" do
    test "simulation is accepted as a budget category" do
      workspace = workspace_fixture()

      assert {:ok, budget} =
               Budgets.create_budget(%{
                 workspace_id: workspace.id,
                 name: "Simulation budget",
                 category: "simulation",
                 period: "monthly",
                 token_limit: 1_000
               })

      assert budget.category == "simulation"
      assert %{"status" => "ok"} = Budgets.budget_status(budget)
    end
  end

  describe "registered simulation tools" do
    test "exposes simulation V2 tools with correct side-effect posture" do
      specs = Registry.all()

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_estimate" and &1.side_effect_class == "read_only")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_create" and &1.side_effect_class == "workspace_write")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_start" and &1.side_effect_class == "workspace_write")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_report" and &1.side_effect_class == "workspace_write")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_cancel" and &1.side_effect_class == "workspace_write")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_duplicate" and &1.side_effect_class == "workspace_write")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_replay" and &1.side_effect_class == "read_only")
             )

      assert Enum.any?(
               specs,
               &(&1.name == "simulation_export" and &1.side_effect_class == "read_only")
             )
    end

    test "simulation tools fail closed on invalid ids and missing workspace context" do
      workspace = workspace_fixture()

      assert {:error, %{"reason" => "simulation_id_invalid"}} =
               Registry.execute(
                 "simulation_start",
                 %{"simulation_id" => "not-an-id"},
                 %{"workspace_id" => workspace.id}
               )

      assert {:error, %{"reason" => "workspace_id_required"}} =
               Registry.execute("simulation_report", %{"simulation_id" => "1"}, %{})
    end

    test "simulation V2 tools execute duplicate, replay, export, and cancel operations" do
      workspace = workspace_fixture()

      {:ok, simulation} =
        Simulation.create_simulation(%{
          workspace_id: workspace.id,
          title: "Tool source",
          goal: "Exercise V2 simulation tools.",
          config: %{"agent_count" => 1, "max_ticks" => 1, "max_budget_cents" => 20}
        })

      assert {:ok, %{"simulation" => %{id: copy_id, status: "configuring"}}} =
               Registry.execute(
                 "simulation_duplicate",
                 %{"simulation_id" => simulation.id, "title" => "Tool copy"},
                 %{"workspace_id" => workspace.id}
               )

      assert {:ok, %{"simulation" => %{id: ^copy_id}, "ticks" => [], "events" => []}} =
               Registry.execute(
                 "simulation_replay",
                 %{"simulation_id" => copy_id},
                 %{"workspace_id" => workspace.id}
               )

      assert {:ok,
              %{"simulation" => %{id: ^copy_id}, "budget_reservation" => %{status: "active"}}} =
               Registry.execute(
                 "simulation_export",
                 %{"simulation_id" => copy_id},
                 %{"workspace_id" => workspace.id}
               )

      assert {:ok, %{"simulation" => %{id: ^copy_id, status: "canceled"}}} =
               Registry.execute(
                 "simulation_cancel",
                 %{"simulation_id" => copy_id},
                 %{"workspace_id" => workspace.id}
               )
    end
  end

  defp wait_for_worker(simulation, attempts \\ 20)
  defp wait_for_worker(simulation, 0), do: Simulation.worker_status(simulation)

  defp wait_for_worker(simulation, attempts) do
    status = Simulation.worker_status(simulation)

    if status.active do
      status
    else
      Process.sleep(10)
      wait_for_worker(simulation, attempts - 1)
    end
  end

  defp wait_for_worker_stop(simulation, attempts \\ 20)
  defp wait_for_worker_stop(simulation, 0), do: Simulation.worker_status(simulation)

  defp wait_for_worker_stop(simulation, attempts) do
    status = Simulation.worker_status(simulation)

    if status.active do
      Process.sleep(10)
      wait_for_worker_stop(simulation, attempts - 1)
    else
      status
    end
  end

  defp replay_signature(simulation) do
    simulation
    |> Simulation.replay()
    |> Map.fetch!("events")
    |> Enum.map(fn event ->
      properties =
        event.properties
        |> Map.drop(["profile_id"])

      {event.tick, event.event_type, event.source, event.target, event.description, properties,
       event.stakes}
    end)
    |> Enum.sort()
  end
end
