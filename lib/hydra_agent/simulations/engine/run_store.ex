defmodule HydraAgent.Simulations.Engine.RunStore do
  @moduledoc "Durable, atomic commit boundary for Quick simulation rounds."

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Runtime.{Run, RunEvent}

  alias HydraAgent.Simulations.{
    BudgetGovernor,
    BudgetPlan,
    ContentHash,
    PopulationCompiler,
    ResourceTransaction,
    RunSnapshot,
    Simulation,
    SimulationRunRecord
  }

  alias HydraAgent.Simulations.Engine.{
    EventRecorder,
    EventRecorder.Event,
    QuickEngine,
    ResourceLedger,
    Snapshotter,
    StateStoreSupervisor
  }

  @terminal_statuses ~w(completed failed canceled)

  def get_record!(record_id) do
    SimulationRunRecord
    |> Repo.get!(record_id)
    |> Repo.preload([
      :run,
      :simulation,
      :simulation_version,
      :context_pack,
      :population_model,
      simulation_script: :preview
    ])
  end

  def latest_snapshot(record_id) do
    RunSnapshot
    |> where([snapshot], snapshot.simulation_run_record_id == ^record_id)
    |> order_by([snapshot], desc: snapshot.round)
    |> limit(1)
    |> Repo.one()
  end

  def load_or_initialize(%SimulationRunRecord{} = record) do
    case latest_snapshot(record.id) do
      nil -> initialize(record)
      snapshot -> restore(record, snapshot)
    end
  end

  def runnable?(record_id) do
    SimulationRunRecord
    |> join(:inner, [record], run in assoc(record, :run))
    |> where([record, run], record.id == ^record_id and run.status in ["planned", "running"])
    |> Repo.exists?()
  end

  def persist_round(record, state, events, transactions) do
    round = state["round"]

    events =
      events ++
        [
          %Event{
            type: "simulation.snapshot",
            phase: "snapshot",
            summary: "Round #{round} recovery point written",
            payload: %{"round" => round},
            source_ref: "snapshot:#{round}",
            provenance: %{"engine_version" => record.engine_version}
          }
        ]

    {prepared_events, next_sequence} =
      EventRecorder.prepare(record.id, record.pack_hash, round, events)

    balances = ResourceLedger.balances(record.id)
    payload = snapshot_payload(record, state, balances, next_sequence)
    snapshot = Snapshotter.build(record.id, payload)

    prepared_events =
      Enum.map(prepared_events, fn event ->
        if event.type == "simulation.snapshot" do
          put_in(event, [:payload], %{
            "round" => round,
            "checksum" => snapshot.checksum,
            "state_hash" => snapshot.state_hash
          })
        else
          event
        end
      end)

    Repo.transaction(fn ->
      locked = lock_record!(record.id)
      run = lock_run!(locked.run_id)

      cond do
        run.status in @terminal_statuses ->
          Repo.rollback({:terminal_fence, run.status})

        locked.current_round >= round ->
          :already_committed

        locked.current_round != round - 1 ->
          Repo.rollback({:round_out_of_order, locked.current_round, round})

        true ->
          insert_simulation_events!(locked, prepared_events)
          insert_resource_transactions!(locked, transactions)
          insert_snapshot!(locked, snapshot, round, next_sequence)

          locked
          |> SimulationRunRecord.changeset(%{
            current_round: round,
            last_event_sequence: next_sequence,
            initial_state_hash: locked.initial_state_hash || snapshot.state_hash,
            started_at: locked.started_at || now()
          })
          |> Repo.update!()

          run
          |> Run.changeset(%{
            status: "running",
            started_at: run.started_at || now(),
            runtime_state: %{
              "kind" => "simulation",
              "current_round" => round,
              "rounds_planned" => locked.rounds_planned,
              "last_event_sequence" => next_sequence,
              "latest_snapshot_checksum" => snapshot.checksum
            }
          })
          |> Repo.update!()

          Simulation
          |> Repo.get!(locked.simulation_id)
          |> Ecto.Changeset.change(status: "running")
          |> Repo.update!()

          :committed
      end
    end)
    |> case do
      {:ok, :committed} ->
        EventRecorder.commit(record.id, next_sequence)
        {:ok, :committed}

      {:ok, :already_committed} ->
        {:ok, :already_committed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete(record, state) do
    result = QuickEngine.result_payload(state, record)
    result_hash = ContentHash.digest(result)

    summary = %{
      "rounds_completed" => result["rounds_completed"],
      "population_size" => result["population_size"],
      "model_calls" => 0,
      "stop_reason" => result["stop_reason"],
      "action_counts" => result["action_counts"],
      "final_observation" => List.last(result["observations"] || []),
      "result_hash" => result_hash
    }

    completion = %Event{
      type: "simulation.completed",
      phase: "complete",
      summary: "Quick simulation completed",
      payload: summary,
      source_ref: "run:complete",
      provenance: %{"engine_version" => record.engine_version, "pack_hash" => record.pack_hash}
    }

    {events, next_sequence} =
      EventRecorder.prepare(record.id, record.pack_hash, state["round"], [completion])

    Repo.transaction(fn ->
      locked = lock_record!(record.id)
      run = lock_run!(locked.run_id)

      cond do
        run.status == "completed" ->
          {:already_completed, locked.result_hash}

        run.status in ["failed", "canceled"] ->
          Repo.rollback({:terminal_fence, run.status})

        true ->
          insert_simulation_events!(locked, events)

          final_state_hash =
            ContentHash.digest(
              Map.take(result, [
                "world",
                "agents",
                "resource_balances",
                "relationships_hash",
                "action_counts",
                "observations"
              ])
            )

          completed_at = now()
          budget = budget_usage(locked)

          updated =
            locked
            |> SimulationRunRecord.changeset(%{
              current_round: state["round"],
              last_event_sequence: next_sequence,
              model_call_count: 0,
              final_state_hash: final_state_hash,
              result_hash: result_hash,
              result_summary: summary,
              budget_used: budget.used,
              fallback_count: budget.fallbacks,
              failure: %{},
              completed_at: completed_at
            })
            |> Repo.update!()

          run
          |> Run.changeset(%{
            status: "completed",
            completed_at: completed_at,
            result: summary,
            runtime_state: %{
              "kind" => "simulation",
              "current_round" => state["round"],
              "rounds_planned" => locked.rounds_planned,
              "last_event_sequence" => next_sequence,
              "terminal_fence" => "completed"
            }
          })
          |> Repo.update!()

          Simulation
          |> Repo.get!(locked.simulation_id)
          |> Ecto.Changeset.change(status: "ready")
          |> Repo.update!()

          {:completed, updated}
      end
    end)
    |> case do
      {:ok, {:completed, updated}} ->
        EventRecorder.commit(record.id, next_sequence)
        {:ok, updated}

      {:ok, {:already_completed, _hash}} ->
        {:ok, get_record!(record.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fail(record_id, reason) do
    failure = safe_failure(reason)

    Repo.transaction(fn ->
      locked = lock_record!(record_id)
      run = lock_run!(locked.run_id)

      if run.status in @terminal_statuses do
        {:terminal, run.status}
      else
        event = %Event{
          type: "simulation.failed",
          phase: "failed",
          summary: "Simulation stopped safely",
          payload: failure,
          source_ref: "run:failed",
          provenance: %{"engine_version" => locked.engine_version}
        }

        {events, next_sequence} =
          EventRecorder.prepare(locked.id, locked.pack_hash, locked.current_round, [event])

        insert_simulation_events!(locked, events)
        completed_at = now()
        budget = budget_usage(locked)

        locked
        |> SimulationRunRecord.changeset(%{
          last_event_sequence: next_sequence,
          budget_used: budget.used,
          fallback_count: budget.fallbacks,
          failure: failure,
          completed_at: completed_at
        })
        |> Repo.update!()

        run
        |> Run.changeset(%{
          status: "failed",
          completed_at: completed_at,
          result: %{"failure" => failure},
          runtime_state: %{"kind" => "simulation", "terminal_fence" => "failed"}
        })
        |> Repo.update!()

        Simulation
        |> Repo.get!(locked.simulation_id)
        |> Ecto.Changeset.change(status: "failed")
        |> Repo.update!()

        {:failed, locked.id, next_sequence}
      end
    end)
    |> case do
      {:ok, {:failed, id, sequence}} ->
        EventRecorder.commit(id, sequence)
        {:ok, :failed}

      {:ok, {:terminal, status}} ->
        {:ok, {:terminal, status}}

      {:error, transaction_reason} ->
        {:error, transaction_reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def record_recovery(record, snapshot) do
    event = %Event{
      type: "simulation.recovered",
      phase: "prepare",
      summary: "Run restored from round #{snapshot.round}",
      payload: %{"snapshot_round" => snapshot.round, "checksum" => snapshot.checksum},
      source_ref: "snapshot:#{snapshot.round}",
      provenance: %{"engine_version" => record.engine_version}
    }

    {events, next_sequence} =
      EventRecorder.prepare(record.id, record.pack_hash, snapshot.round, [event])

    Repo.transaction(fn ->
      locked = lock_record!(record.id)
      run = lock_run!(locked.run_id)

      if run.status in ["planned", "running"] do
        insert_simulation_events!(locked, events)

        locked
        |> SimulationRunRecord.changeset(%{
          recovery_count: locked.recovery_count + 1,
          last_event_sequence: next_sequence
        })
        |> Repo.update!()

        :recorded
      else
        Repo.rollback({:terminal_fence, run.status})
      end
    end)
    |> case do
      {:ok, :recorded} ->
        EventRecorder.commit(record.id, next_sequence)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initialize(record) do
    population = record.population_model
    script = record.simulation_script.script

    with {:ok, compiled} <-
           PopulationCompiler.compile(HydraAgent.Simulations.PopulationModel.contract(population),
             population_size: population.population_size,
             seed: record.seed
           ),
         :ok <-
           ResourceLedger.load(
             record.id,
             script["resources"] || [],
             compiled.agents,
             get_in(script, ["world", "resources"]) || %{}
           ) do
      state = QuickEngine.initial_state(compiled, script)
      agents = ResourceLedger.hydrate_agents(record.id, state["agents"])
      state = Map.put(state, "agents", agents)
      StateStoreSupervisor.load(record.id, agents, record.partition_count)

      event = %Event{
        type: "simulation.prepared",
        phase: "prepare",
        summary: "Full population compiled for Quick execution",
        payload: %{
          "population_size" => length(agents),
          "relationship_count" => length(compiled.relationships),
          "partition_count" => record.partition_count,
          "model_calls" => 0
        },
        source_ref: "population:#{record.population_model_id}",
        provenance: %{
          "population_hash" => population.content_hash,
          "script_hash" => record.simulation_script.content_hash,
          "engine_version" => record.engine_version
        }
      }

      {events, next_sequence} =
        EventRecorder.prepare(record.id, record.pack_hash, 0, [event])

      balances = ResourceLedger.balances(record.id)
      payload = snapshot_payload(record, state, balances, next_sequence)
      snapshot = Snapshotter.build(record.id, payload)

      case persist_initial(record, events, snapshot, next_sequence) do
        :ok ->
          EventRecorder.commit(record.id, next_sequence)
          {:ok, state, :initialized}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp restore(record, snapshot) do
    with :ok <- verify_snapshot_lineage(record, snapshot),
         {:ok, state_hash} <- Snapshotter.verify_payload(snapshot.payload, snapshot.checksum),
         :ok <- verify_snapshot_state_hash(snapshot, state_hash) do
      state =
        Map.take(snapshot.payload, [
          "round",
          "world",
          "agents",
          "relationships",
          "action_counts",
          "observations",
          "recent_events",
          "unchanged_rounds",
          "stop_reason"
        ])

      :ok =
        ResourceLedger.restore(
          record.id,
          record.simulation_script.script["resources"] || [],
          snapshot.payload["balances"] || %{}
        )

      :ok = StateStoreSupervisor.load(record.id, state["agents"], record.partition_count)
      :ok = EventRecorder.reset(record.id, record.last_event_sequence)

      if record.current_round > 0 and record.run.status in ["planned", "running"] do
        case record_recovery(record, snapshot) do
          :ok -> {:ok, state, :recovered}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, state, :restored}
      end
    end
  end

  @doc false
  def verify_snapshot(record, snapshot) do
    with :ok <- verify_snapshot_lineage(record, snapshot),
         {:ok, state_hash} <- Snapshotter.verify_payload(snapshot.payload, snapshot.checksum),
         :ok <- verify_snapshot_state_hash(snapshot, state_hash) do
      :ok
    end
  end

  defp verify_snapshot_lineage(record, snapshot) do
    payload = snapshot.payload

    expected = %{
      schema_version: 1,
      engine_version: record.engine_version,
      pack_hash: record.pack_hash,
      seed: record.seed,
      round: snapshot.round,
      event_sequence: snapshot.event_sequence
    }

    actual = %{
      schema_version: payload["schema_version"],
      engine_version: payload["engine_version"],
      pack_hash: payload["pack_hash"],
      seed: payload["seed"],
      round: payload["round"],
      event_sequence: payload["event_sequence"]
    }

    scopes_match? =
      snapshot.simulation_run_record_id == record.id and
        snapshot.workspace_id == record.workspace_id and snapshot.run_id == record.run_id

    if scopes_match? and actual == expected,
      do: :ok,
      else: {:error, :snapshot_lineage_mismatch}
  end

  defp verify_snapshot_state_hash(snapshot, state_hash) do
    if snapshot.state_hash == state_hash,
      do: :ok,
      else: {:error, :snapshot_state_hash_mismatch}
  end

  defp budget_usage(record) do
    plan = Repo.get!(BudgetPlan, record.budget_plan_id)

    summary =
      BudgetGovernor.summary(plan, simulation_run_record_id: record.id)

    %{
      fallbacks: summary["fallbacks"],
      used: %{
        "currency" => summary["currency"],
        "pricing_status" => summary["pricing_status"],
        "cost" => summary["used_cost"],
        "input_tokens" => summary["input_tokens"],
        "output_tokens" => summary["output_tokens"],
        "model_calls" => summary["model_calls"],
        "retrieval_requests" => summary["retrieval_requests"]
      }
    }
  end

  defp persist_initial(record, events, snapshot, next_sequence) do
    Repo.transaction(fn ->
      locked = lock_record!(record.id)
      run = lock_run!(locked.run_id)

      if run.status in @terminal_statuses do
        Repo.rollback({:terminal_fence, run.status})
      end

      if Repo.exists?(
           from(s in RunSnapshot,
             where: s.simulation_run_record_id == ^locked.id and s.round == 0
           )
         ) do
        :already_initialized
      else
        insert_simulation_events!(locked, events)
        insert_snapshot!(locked, snapshot, 0, next_sequence)
        started_at = now()

        locked
        |> SimulationRunRecord.changeset(%{
          current_round: 0,
          last_event_sequence: next_sequence,
          initial_state_hash: snapshot.state_hash,
          started_at: started_at
        })
        |> Repo.update!()

        run
        |> Run.changeset(%{
          status: "running",
          started_at: run.started_at || started_at,
          runtime_state: %{
            "kind" => "simulation",
            "current_round" => 0,
            "rounds_planned" => locked.rounds_planned,
            "last_event_sequence" => next_sequence,
            "latest_snapshot_checksum" => snapshot.checksum
          }
        })
        |> Repo.update!()

        %RunEvent{}
        |> RunEvent.changeset(%{
          workspace_id: locked.workspace_id,
          run_id: locked.run_id,
          event_type: "run.started",
          summary: "Run started",
          payload: %{"kind" => "simulation", "mode" => "quick"}
        })
        |> Repo.insert!()

        Simulation
        |> Repo.get!(locked.simulation_id)
        |> Ecto.Changeset.change(status: "running")
        |> Repo.update!()

        :initialized
      end
    end)
    |> case do
      {:ok, status} when status in [:initialized, :already_initialized] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_payload(record, state, balances, event_sequence) do
    state
    |> Map.merge(%{
      "schema_version" => 1,
      "engine_version" => record.engine_version,
      "pack_hash" => record.pack_hash,
      "seed" => record.seed,
      "event_sequence" => event_sequence,
      "balances" => balances
    })
  end

  defp insert_snapshot!(record, snapshot, round, event_sequence) do
    %RunSnapshot{}
    |> RunSnapshot.changeset(%{
      workspace_id: record.workspace_id,
      run_id: record.run_id,
      simulation_run_record_id: record.id,
      round: round,
      event_sequence: event_sequence,
      schema_version: 1,
      engine_version: record.engine_version,
      payload: snapshot.payload,
      state_hash: snapshot.state_hash,
      checksum: snapshot.checksum
    })
    |> Repo.insert!()
  end

  defp insert_simulation_events!(record, events) do
    now = now()

    rows =
      Enum.map(events, fn event ->
        %{
          workspace_id: record.workspace_id,
          run_id: record.run_id,
          event_type: event.type,
          summary: event.summary,
          payload: event.payload || %{},
          sequence: event.sequence,
          round: event.round,
          phase: event.phase,
          actor_key: event.actor_key,
          targets: event.targets || [],
          source_ref: event.source_ref,
          provenance: event.provenance || %{},
          idempotency_key: event.idempotency_key,
          inserted_at: now
        }
      end)

    if rows != [], do: Repo.insert_all(RunEvent, rows)
  end

  defp insert_resource_transactions!(record, transactions) do
    if transactions != [] do
      current_sequence =
        ResourceTransaction
        |> where([transaction], transaction.run_id == ^record.run_id)
        |> select([transaction], max(transaction.sequence))
        |> Repo.one()
        |> Kernel.||(0)

      now = now()

      rows =
        transactions
        |> Enum.with_index(current_sequence + 1)
        |> Enum.map(fn {transaction, sequence} ->
          %{
            workspace_id: record.workspace_id,
            run_id: record.run_id,
            simulation_run_record_id: record.id,
            sequence: sequence,
            round: transaction["round"],
            phase: transaction["phase"],
            resource_id: transaction["resource_id"],
            source_account: transaction["source_account"],
            destination_account: transaction["destination_account"],
            amount: Decimal.new(transaction["amount"]),
            operation: transaction["operation"],
            source_ref: transaction["source_ref"],
            tags: transaction["tags"] || [],
            resulting_balances: transaction["resulting_balances"] || %{},
            idempotency_key: transaction["idempotency_key"],
            inserted_at: now
          }
        end)

      Repo.insert_all(ResourceTransaction, rows)
    end
  end

  defp lock_record!(record_id) do
    SimulationRunRecord
    |> where([record], record.id == ^record_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_run!(run_id) do
    Run
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp safe_failure(reason) do
    %{
      "code" => failure_code(reason),
      "message" =>
        "The run stopped before publishing a result. Its last committed snapshot is preserved."
    }
  end

  defp failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(code) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(_reason), do: "simulation_failed"
  defp now, do: DateTime.utc_now()
end
