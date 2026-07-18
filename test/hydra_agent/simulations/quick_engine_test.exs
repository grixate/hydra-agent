defmodule HydraAgent.Simulations.QuickEngineTest do
  use HydraAgent.DataCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import Ecto.Query
  import HydraAgent.RuntimeFixtures

  alias Decimal, as: D
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.{Run, RunEvent}

  alias HydraAgent.Simulations.{
    Blueprints,
    ResourceTransaction,
    RunSnapshot,
    SimulationRunRecord
  }

  alias HydraAgent.Simulations.Engine
  alias HydraAgent.Simulations.Engine.{QuickEngine, ResourceLedger, RunStore}
  alias HydraAgent.Simulations.Engine.Supervisor, as: EngineSupervisor

  setup do
    workspace = workspace_fixture(%{name: "Quick Engine", slug: "quick-engine"})
    [general, _decision_replay] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general}
  end

  test "Quick mode completes without model calls and commits ordered recovery points", context do
    simulation = simulation_fixture(context, 40, "3 rounds")
    assert {:ok, record} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert record.run.status == "planned"

    assert {:ok, completed} = Engine.execute(record.id)
    completed = HydraAgent.Simulations.get_simulation_run_record!(completed.id)

    assert completed.run.status == "completed"
    assert completed.current_round == 3
    assert completed.model_call_count == 0
    assert completed.result_summary["population_size"] == 40
    assert completed.result_summary["model_calls"] == 0
    assert byte_size(completed.result_hash) == 64
    assert byte_size(completed.initial_state_hash) == 64
    assert byte_size(completed.final_state_hash) == 64

    assert Repo.aggregate(
             from(snapshot in RunSnapshot,
               where: snapshot.simulation_run_record_id == ^completed.id
             ),
             :count
           ) == 4

    events =
      RunEvent
      |> where([event], event.run_id == ^completed.run_id and not is_nil(event.sequence))
      |> order_by([event], asc: event.sequence)
      |> Repo.all()

    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert Enum.any?(events, &(&1.event_type == "simulation.prepared"))
    assert Enum.any?(events, &(&1.event_type == "simulation.completed"))
    assert Enum.all?(events, &is_binary(&1.idempotency_key))
  end

  test "the same Pack and seed produce the same authoritative result hash", context do
    simulation = simulation_fixture(context, 30, "4 rounds")

    assert {:ok, first} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert {:ok, first} = Engine.execute(first.id)

    assert {:ok, second} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert {:ok, second} = Engine.execute(second.id)

    assert first.pack_hash == second.pack_hash
    assert first.result_hash == second.result_hash
    assert first.final_state_hash == second.final_state_hash
    assert first.model_call_count == 0
    assert second.model_call_count == 0
  end

  test "snapshot verification fails closed on lineage, checksum, and state hash changes",
       context do
    simulation = simulation_fixture(context, 20, "2 rounds")
    assert {:ok, record} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert {:ok, completed} = Engine.execute(record.id)
    completed = HydraAgent.Simulations.get_simulation_run_record!(completed.id)

    snapshot =
      RunSnapshot
      |> where([snapshot], snapshot.simulation_run_record_id == ^completed.id)
      |> order_by([snapshot], desc: snapshot.round)
      |> limit(1)
      |> Repo.one!()

    assert :ok = RunStore.verify_snapshot(completed, snapshot)

    wrong_lineage =
      %{snapshot | payload: Map.put(snapshot.payload, "pack_hash", String.duplicate("0", 64))}

    assert {:error, :snapshot_lineage_mismatch} =
             RunStore.verify_snapshot(completed, wrong_lineage)

    assert {:error, :checksum_mismatch} =
             RunStore.verify_snapshot(completed, %{
               snapshot
               | checksum: String.duplicate("0", 64)
             })

    assert {:error, :snapshot_state_hash_mismatch} =
             RunStore.verify_snapshot(completed, %{
               snapshot
               | state_hash: String.duplicate("0", 64)
             })
  end

  test "relationship effects and bounded neighbor transitions execute deterministically" do
    run_record_id = Ecto.UUID.generate()
    start_supervised!({ResourceLedger, run_record_id: run_record_id})

    agents = [
      %{
        "id" => "agent-a",
        "type" => "source",
        "attributes" => %{"trust" => 0.5},
        "state" => %{},
        "resources" => %{}
      },
      %{
        "id" => "agent-b",
        "type" => "target",
        "attributes" => %{"trust" => 0.5},
        "state" => %{},
        "resources" => %{}
      }
    ]

    relationships = [
      %{
        "id" => "relationship-1",
        "type" => "trusts",
        "source" => "agent-a",
        "target" => "agent-b",
        "weight" => 0.8,
        "directed" => true,
        "state" => %{}
      }
    ]

    script = relationship_script()
    assert :ok = ResourceLedger.load(run_record_id, [], agents, %{})

    state = QuickEngine.initial_state(%{agents: agents, relationships: relationships}, script)
    assert {:ok, result} = QuickEngine.run_round(run_record_id, state, script, 1, 17)

    [source, target] = result.state["agents"]
    [relationship] = result.state["relationships"]

    assert source["id"] == "agent-a"
    assert target["id"] == "agent-b"
    assert relationship["weight"] == 0.6
    assert target["attributes"]["trust"] == 0.44
    assert target["state"]["transition_chain"] == "complete"
    assert result.state["action_counts"] == %{"oppose" => 1, "wait" => 1}
    assert Enum.any?(result.events, &(&1.type == "simulation.transition"))
  end

  test "Resource Ledger conserves transfers and ignores a retried idempotency key" do
    definitions = [
      %{
        "id" => "time",
        "precision" => 2,
        "constraints" => %{"min" => 0, "max" => 100},
        "mint_allowed" => true,
        "burn_allowed" => true
      }
    ]

    state =
      ResourceLedger.new_state(definitions, %{
        "agent:a" => %{"time" => "10.00"},
        "agent:b" => %{"time" => "4.00"}
      })

    transaction = %{
      operation: "transfer",
      resource_id: "time",
      source_account: "agent:a",
      destination_account: "agent:b",
      amount: "3.25",
      round: 1,
      phase: "actions",
      source_ref: "action:share",
      tags: ["transfer"],
      idempotency_key: String.duplicate("a", 64)
    }

    assert {:ok, [applied], next} = ResourceLedger.apply_transactions(state, [transaction])
    assert applied["resulting_balances"] == %{"source" => "6.75", "destination" => "7.25"}
    assert D.equal?(next.balances[{"agent:a", "time"}], D.new("6.75"))
    assert D.equal?(next.balances[{"agent:b", "time"}], D.new("7.25"))

    total = D.add(next.balances[{"agent:a", "time"}], next.balances[{"agent:b", "time"}])
    assert D.equal?(total, D.new("14.00"))

    assert {:ok, [], retried} = ResourceLedger.apply_transactions(next, [transaction])
    assert retried.balances == next.balances
  end

  test "Resource Ledger conserves bounded transfers across its declared precision" do
    definitions = [
      %{
        "id" => "credits",
        "precision" => 2,
        "constraints" => %{"min" => 0, "max" => 100},
        "mint_allowed" => false,
        "burn_allowed" => false
      }
    ]

    Enum.each(0..1_000//7, fn cents ->
      amount = cents |> D.new() |> D.div(100)

      state =
        ResourceLedger.new_state(definitions, %{
          "agent:a" => %{"credits" => "10.00"},
          "agent:b" => %{"credits" => "0.00"}
        })

      transaction = %{
        operation: "transfer",
        resource_id: "credits",
        source_account: "agent:a",
        destination_account: "agent:b",
        amount: amount,
        idempotency_key: "transfer-#{cents}-#{String.duplicate("x", 16)}"
      }

      assert {:ok, [_applied], next} = ResourceLedger.apply_transactions(state, [transaction])

      total =
        D.add(
          next.balances[{"agent:a", "credits"}],
          next.balances[{"agent:b", "credits"}]
        )

      assert D.equal?(total, D.new("10.00"))
      refute D.negative?(next.balances[{"agent:a", "credits"}])
      refute D.negative?(next.balances[{"agent:b", "credits"}])
    end)

    state =
      ResourceLedger.new_state(definitions, %{
        "agent:a" => %{"credits" => "10.00"},
        "agent:b" => %{"credits" => "0.00"}
      })

    rounded_transfer = %{
      operation: "transfer",
      resource_id: "credits",
      source_account: "agent:a",
      destination_account: "agent:b",
      amount: "0.005",
      idempotency_key: String.duplicate("p", 64)
    }

    assert {:ok, [_applied], rounded} =
             ResourceLedger.apply_transactions(state, [rounded_transfer])

    assert D.equal?(rounded.balances[{"agent:a", "credits"}], D.new("9.99"))
    assert D.equal?(rounded.balances[{"agent:b", "credits"}], D.new("0.01"))
  end

  test "Resource Ledger rejects overdrafts and disallowed supply changes atomically" do
    definitions = [
      %{
        "id" => "credits",
        "precision" => 2,
        "constraints" => %{"min" => 0, "max" => 100},
        "mint_allowed" => false,
        "burn_allowed" => false
      }
    ]

    state = ResourceLedger.new_state(definitions, %{"agent:a" => %{"credits" => "1.00"}})

    overdraft = %{
      operation: "transfer",
      resource_id: "credits",
      source_account: "agent:a",
      destination_account: "agent:b",
      amount: "1.01",
      idempotency_key: String.duplicate("o", 64)
    }

    assert {:error, {:negative_balance, "agent:a", "credits"}} =
             ResourceLedger.apply_transactions(state, [overdraft])

    mint = %{
      operation: "mint",
      resource_id: "credits",
      destination_account: "agent:a",
      amount: "1.00",
      idempotency_key: String.duplicate("m", 64)
    }

    assert {:error, :mint_not_allowed} = ResourceLedger.apply_transactions(state, [mint])

    credit_adjustment = %{
      operation: "adjust",
      resource_id: "credits",
      destination_account: "agent:a",
      amount: "0.25",
      idempotency_key: String.duplicate("c", 64)
    }

    debit_adjustment = %{
      operation: "adjust",
      resource_id: "credits",
      source_account: "agent:a",
      amount: "-0.25",
      idempotency_key: String.duplicate("d", 64)
    }

    assert {:error, :mint_not_allowed} =
             ResourceLedger.apply_transactions(state, [credit_adjustment])

    assert {:error, :burn_not_allowed} =
             ResourceLedger.apply_transactions(state, [debit_adjustment])

    assert D.equal?(state.balances[{"agent:a", "credits"}], D.new("1.00"))
    refute Map.has_key?(state.balances, {"agent:b", "credits"})
  end

  test "Quick run creation returns specific validation errors", context do
    simulation = simulation_fixture(context, 20, "2 rounds")

    assert {:error, :invalid_seed} =
             HydraAgent.Simulations.create_quick_run(simulation, nil, seed: -1)

    assert {:error, :invalid_partition_count} =
             HydraAgent.Simulations.create_quick_run(simulation, nil, partition_count: 0)
  end

  test "snapshot and ledger rows fail closed outside their exact Run scope", context do
    simulation = simulation_fixture(context, 20, "2 rounds")
    assert {:ok, record} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert {:ok, completed} = Engine.execute(record.id)

    other_workspace =
      workspace_fixture(%{name: "Other Quick Scope", slug: "other-quick-scope"})

    other_run =
      %Run{}
      |> Run.changeset(%{
        workspace_id: other_workspace.id,
        title: "Other run",
        goal: "Prove child scope",
        status: "planned",
        autonomy_level: "recommend"
      })
      |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/simulation run child is not exact/, fn ->
      Repo.transaction(fn ->
        %RunSnapshot{}
        |> RunSnapshot.changeset(%{
          workspace_id: other_workspace.id,
          run_id: other_run.id,
          simulation_run_record_id: completed.id,
          round: completed.rounds_planned + 1,
          event_sequence: 10_000,
          schema_version: 1,
          engine_version: completed.engine_version,
          payload: %{"round" => completed.rounds_planned + 1},
          state_hash: String.duplicate("a", 64),
          checksum: String.duplicate("b", 64)
        })
        |> Repo.insert!()
      end)
    end

    assert_raise Postgrex.Error, ~r/simulation run child is not exact/, fn ->
      Repo.transaction(fn ->
        %ResourceTransaction{}
        |> ResourceTransaction.changeset(%{
          workspace_id: other_workspace.id,
          run_id: other_run.id,
          simulation_run_record_id: completed.id,
          sequence: 10_000,
          round: 1,
          phase: "actions",
          resource_id: "time",
          source_account: "agent:a",
          destination_account: "agent:b",
          amount: "1.00",
          operation: "transfer",
          source_ref: "test:scope",
          tags: ["test"],
          resulting_balances: %{},
          idempotency_key: String.duplicate("c", 64)
        })
        |> Repo.insert!()
      end)
    end

    snapshot =
      Repo.get_by!(RunSnapshot,
        simulation_run_record_id: completed.id,
        round: completed.current_round
      )

    assert_raise Postgrex.Error, ~r/run_snapshots is append-only/, fn ->
      Repo.delete!(snapshot)
    end

    Repo.delete!(completed)

    refute Repo.exists?(
             from(current in RunSnapshot,
               where: current.simulation_run_record_id == ^completed.id
             )
           )
  end

  test "a killed coordinator resumes from the latest checksummed snapshot", context do
    simulation = simulation_fixture(context, 60, "6 rounds")
    assert {:ok, record} = HydraAgent.Simulations.create_quick_run(simulation, nil)

    assert {:ok, _supervisor} =
             EngineSupervisor.start_run(record, pause_after_round: 1, notify_pid: self())

    assert_receive {:simulation_round_committed, coordinator, 1}, 2_000
    Process.exit(coordinator, :kill)
    assert {:ok, completed} = Engine.execute(record.id)
    completed = Repo.get!(SimulationRunRecord, completed.id)

    assert completed.current_round == 6
    assert completed.recovery_count >= 1
    assert completed.result_hash
    assert Repo.aggregate(ResourceTransaction, :count) >= 0
  end

  test "operator cancellation writes a terminal fence that cannot resume", context do
    simulation = simulation_fixture(context, 80, "8 rounds")
    assert {:ok, record} = HydraAgent.Simulations.create_quick_run(simulation, nil)
    assert {:ok, _supervisor} = EngineSupervisor.start_run(record, round_delay_ms: 40)
    assert eventually(fn -> current_round(record.id) >= 1 end)

    assert {:ok, canceled} = HydraAgent.Simulations.cancel_quick_run(record, nil)
    assert canceled.run.status == "canceled"
    committed_round = canceled.current_round

    assert {:error, {:terminal_fence, "canceled"}} = Engine.execute(record.id)
    assert Repo.get!(SimulationRunRecord, record.id).current_round == committed_round
    assert Repo.get!(Run, record.run_id).status == "canceled"
  end

  defp simulation_fixture(%{workspace: workspace, general: general}, size, horizon) do
    assert {:ok, simulation} =
             HydraAgent.Simulations.create_simulation(workspace, nil, %{
               "question" => "How might a bounded intervention change participant behavior?",
               "blueprint_id" => general.id,
               "locale" => "en",
               "execution_mode" => "quick",
               "population_size" => Integer.to_string(size),
               "horizon" => horizon,
               "inputs" => %{}
             })

    simulation
  end

  defp relationship_script do
    %{
      "metadata" => %{"id" => "relationship_test"},
      "hydra_simulation_script" => 1,
      "clock" => %{"count" => 1},
      "world" => %{"state" => %{}},
      "resources" => [],
      "events" => [],
      "agent_types" => [
        %{"id" => "source", "policy" => "source_policy"},
        %{"id" => "target", "policy" => "target_policy"}
      ],
      "policies" => [
        %{"id" => "source_policy", "kind" => "fixed", "action" => "oppose"},
        %{"id" => "target_policy", "kind" => "fixed", "action" => "wait"}
      ],
      "actions" => [
        %{
          "id" => "oppose",
          "actors" => ["source"],
          "effects" => [
            %{
              "op" => "adjust_relationship",
              "relationship" => "trusts",
              "target" => %{"self" => true},
              "value" => -0.2
            }
          ],
          "emits" => [
            %{"type" => "opinion_shared", "payload" => %{"stance" => "opposed"}}
          ]
        },
        %{"id" => "wait", "actors" => ["target"], "effects" => [], "emits" => []}
      ],
      "transitions" => [
        %{
          "id" => "trust_decay",
          "when" => %{
            "event_type" => "opinion_shared",
            "payload" => %{"stance" => "opposed"}
          },
          "target" => %{
            "relationship_neighbors" => %{"type" => "trusts", "limit" => 30}
          },
          "effects" => [
            %{
              "op" => "adjust_attribute",
              "path" => "attributes.trust",
              "value" => %{
                "multiply" => [%{"fact" => "event.relationship_weight"}, -0.1]
              }
            }
          ],
          "emits" => [%{"type" => "trust_changed", "payload" => %{}}]
        },
        %{
          "id" => "after_trust_decay",
          "when" => %{"event_type" => "trust_changed"},
          "target" => %{"self" => true},
          "effects" => [
            %{
              "op" => "set_agent",
              "path" => "state.transition_chain",
              "value" => "complete"
            }
          ]
        }
      ],
      "observations" => %{"metrics" => []},
      "stopping_conditions" => [%{"kind" => "final_round"}]
    }
  end

  defp current_round(record_id), do: Repo.get!(SimulationRunRecord, record_id).current_round

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
