defmodule HydraAgent.SimLab.Simulations do
  @moduledoc """
  Scenario, simulation-run, and compact replay-snapshot persistence.
  """

  import Ecto.Query

  alias HydraAgent.Repo

  alias HydraAgent.SimLab.{
    Costing,
    Notifications,
    RepresentativeTrace,
    ScenarioCompiler,
    SimulationRunner
  }

  alias HydraAgent.SimLab.Workers.SimulationRunWorker

  alias HydraAgent.SimLab.Schemas.{
    ContextPack,
    ForecastReport,
    OutcomeEvent,
    Scenario,
    SimulationRun,
    SimulationSnapshot,
    Study
  }

  @valid_run_transitions %{
    "queued" => ["running", "failed", "cancelled"],
    "running" => ["completed", "failed", "cancelled"],
    "completed" => [],
    "failed" => [],
    "cancelled" => []
  }

  @transition_lock_event [:hydra_agent, :sim_lab, :run_transition, :locked]

  def create_scenario(%Study{} = study, attrs) do
    attrs = Map.put_new(attrs, :study_id, study.id)
    %Scenario{} |> Scenario.changeset(attrs) |> Repo.insert()
  end

  def generate_scenario_draft(%Study{} = study, context_pack) do
    Repo.transaction(fn ->
      Study
      |> where([saved], saved.id == ^study.id and saved.workspace_id == ^study.workspace_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      if Repo.exists?(from scenario in Scenario, where: scenario.study_id == ^study.id) do
        Repo.rollback(:scenarios_already_exist)
      end

      %{base: base_attrs, variants: variant_attrs} = ScenarioCompiler.compile(study, context_pack)

      base =
        %Scenario{}
        |> Scenario.changeset(Map.put(base_attrs, :study_id, study.id))
        |> Repo.insert!()

      variants =
        Enum.map(variant_attrs, fn attrs ->
          %Scenario{}
          |> Scenario.changeset(
            attrs
            |> Map.put(:study_id, study.id)
            |> Map.put(:variant_of_id, base.id)
            |> Map.update!(:metadata, &Map.put(&1, "created_as_variant", true))
          )
          |> Repo.insert!()
        end)

      %{base: base, variants: variants, generated: [base | variants]}
    end)
  end

  def list_scenarios(%Study{id: study_id}), do: list_scenarios(study_id)

  def list_scenarios(study_id) do
    Scenario
    |> where([scenario], scenario.study_id == ^study_id)
    |> order_by([scenario], desc: scenario.inserted_at)
    |> Repo.all()
  end

  def get_scenario!(%Study{} = study, scenario_id) do
    Scenario
    |> where([scenario], scenario.study_id == ^study.id and scenario.id == ^scenario_id)
    |> Repo.one!()
  end

  @doc """
  Refines a scenario only before it has been used in a run. Completed runs keep
  their original scenario meaning; researchers create a linked variant when a
  new counterfactual is needed.
  """
  def update_scenario(%Study{} = study, scenario_id, attrs) do
    with %Scenario{} = scenario <- get_scenario(study, scenario_id),
         false <- scenario_has_runs?(scenario) do
      metadata =
        scenario.metadata
        |> then(&(&1 || %{}))
        |> Map.merge(Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{})))
        |> Map.put("refined_in_workspace", true)

      scenario
      |> Scenario.changeset(Map.put(attrs, :metadata, metadata))
      |> Repo.update()
    else
      nil -> {:error, :scenario_not_in_study}
      true -> {:error, :scenario_has_runs}
    end
  end

  def create_variant(%Study{} = study, %Scenario{} = scenario, attrs \\ %{}) do
    attrs = Map.new(attrs)

    create_scenario(study, %{
      name: Map.get(attrs, :name) || "#{scenario.name} · Variant",
      description: Map.get(attrs, :description) || scenario.description,
      forecast_horizon: scenario.forecast_horizon,
      events: scenario.events,
      available_actions: scenario.available_actions,
      success_metrics: scenario.success_metrics,
      constraints: scenario.constraints,
      variant_of_id: scenario.id,
      metadata: Map.put(scenario.metadata || %{}, "created_as_variant", true)
    })
  end

  @doc """
  Creates an explicit, assumption-marked control-first counterfactual from a
  completed run. It never alters the original scenario or forecast.
  """
  def create_control_first_variant(%Study{} = study, %SimulationRun{} = run) do
    scenario =
      case run.scenario do
        %Scenario{} = scenario -> scenario
        _ -> get_scenario!(study, run.scenario_id)
      end

    create_scenario(study, %{
      name: "#{scenario.name} · Opt-in control",
      description:
        "#{scenario.description} This counterfactual makes visibility opt-in and foregrounds user control.",
      forecast_horizon: scenario.forecast_horizon,
      events: control_first_events(scenario.events),
      available_actions: scenario.available_actions,
      success_metrics: scenario.success_metrics,
      constraints: scenario.constraints,
      variant_of_id: scenario.id,
      metadata:
        Map.merge(scenario.metadata || %{}, %{
          "created_as_counterfactual" => true,
          "counterfactual_basis" => "control_uncertainty",
          "base_run_id" => run.id,
          "simulation_modifier" => "control_first_opt_in"
        })
    })
  end

  def compare_runs(%Study{} = study, base_run_id, variant_run_id) do
    base = get_run!(study, base_run_id)
    variant = get_run!(study, variant_run_id)

    deltas =
      Map.new(~w(adopt resist ignore share), fn action ->
        {action,
         Float.round(
           (variant.aggregate_metrics[action] || 0.0) - (base.aggregate_metrics[action] || 0.0),
           4
         )}
      end)

    %{
      base: base,
      variant: variant,
      deltas: deltas,
      recommendation: comparison_recommendation(variant, deltas)
    }
  end

  def create_run(attrs), do: %SimulationRun{} |> SimulationRun.changeset(attrs) |> Repo.insert()

  @doc """
  Persists a queued run and its safe compiled input before handing only the run
  identifier to Oban. The worker can therefore resume after a process restart
  without rereading mutable personas, patterns, or source text.
  """
  def queue_run(
        %Study{} = study,
        %Scenario{} = scenario,
        %ContextPack{} = context_pack,
        input,
        opts \\ %{}
      ) do
    opts = opts |> Map.new() |> Map.put_new(:evidence_map, context_pack.source_mix || %{})
    mode = Map.get(opts, :mode, "small")
    budget_cap = Map.get(opts, :budget_cap_usd, Costing.estimate(mode).high_usd)
    confidence = Map.get(opts, :confidence, 0.6)
    input_snapshot = SimulationRunner.snapshot_input(input)

    with {:ok, _estimate} <- Costing.authorize(mode, budget_cap) do
      Repo.transaction(fn ->
        run =
          create_run!(%{
            study_id: study.id,
            scenario_id: scenario.id,
            context_pack_id: context_pack.id,
            mode: mode,
            agent_count: input.agent_count,
            rounds: length(input.events),
            seed: input.seed,
            status: "queued",
            budget_cap_usd: budget_cap,
            decision_counts: %{},
            aggregate_metrics: %{},
            input_snapshot: input_snapshot,
            input_fingerprint: SimulationRunner.input_fingerprint(input_snapshot),
            execution_options: SimulationRunner.execution_options(opts, confidence),
            confidence: confidence
          })

        case Oban.insert(SimulationRunWorker.new(%{"run_id" => run.id})) do
          {:ok, job} -> %{run: run, job: job}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  def add_snapshot(%SimulationRun{} = run, attrs) do
    attrs = Map.put_new(attrs, :run_id, run.id)
    %SimulationSnapshot{} |> SimulationSnapshot.changeset(attrs) |> Repo.insert()
  end

  def add_outcome_event(%SimulationRun{} = run, attrs) do
    attrs = Map.put_new(attrs, :run_id, run.id)
    %OutcomeEvent{} |> OutcomeEvent.changeset(attrs) |> Repo.insert()
  end

  def list_outcome_events(%SimulationRun{id: run_id}), do: list_outcome_events(run_id)

  def list_outcome_events(run_id) do
    OutcomeEvent
    |> where([event], event.run_id == ^run_id)
    |> order_by([event], asc: event.tick, asc: event.id)
    |> Repo.all()
  end

  def replay_snapshots(%SimulationRun{id: run_id}), do: replay_snapshots(run_id)

  def replay_snapshots(run_id) do
    SimulationSnapshot
    |> where([snapshot], snapshot.run_id == ^run_id)
    |> order_by([snapshot], asc: snapshot.tick)
    |> Repo.all()
  end

  def list_pending_runs(%Study{id: study_id}) do
    SimulationRun
    |> where([run], run.study_id == ^study_id and run.status in ["queued", "running"])
    |> order_by([run], desc: run.inserted_at)
    |> preload(:scenario)
    |> Repo.all()
  end

  @doc """
  Cancels a study-scoped queued or running replay. The run is marked cancelled
  before the Oban job is signalled, so a worker can never publish a forecast
  after the researcher has withdrawn it.
  """
  def cancel_run(%Study{} = study, run_id) do
    result =
      Repo.transaction(fn ->
        case lock_run(run_id, "cancelled", study.id) do
          nil ->
            Repo.rollback(:run_not_in_study)

          %SimulationRun{status: status} = run when status in ["queued", "running"] ->
            transition_run!(run, "cancelled")

          %SimulationRun{} ->
            Repo.rollback(:run_not_cancellable)
        end
      end)

    case result do
      {:ok, cancelled_run} ->
        cancel_oban_jobs(cancelled_run.id)

        Notifications.broadcast(cancelled_run.study_id, %{
          kind: "simulation",
          status: "cancelled",
          run_id: cancelled_run.id
        })

        {:ok, cancelled_run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def fail_run(run_id) do
    result =
      Repo.transaction(fn ->
        case lock_run(run_id, "failed") do
          %SimulationRun{status: status} = run when status in ["queued", "running"] ->
            transition_run!(run, "failed")

          _ ->
            :noop
        end
      end)

    case result do
      {:ok, %SimulationRun{} = failed_run} ->
        Notifications.broadcast(failed_run.study_id, %{
          kind: "simulation",
          status: "failed",
          run_id: failed_run.id
        })

        :ok

      {:ok, :noop} ->
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns an on-demand deterministic representative cohort trace. It is built
  from compact snapshots and never exposes an individual-agent ledger.
  """
  def representative_trace(%SimulationRun{} = run, agent_id, legacy_patterns \\ []) do
    RepresentativeTrace.build(
      run,
      replay_snapshots(run),
      agent_id,
      patterns_for_run(run, legacy_patterns)
    )
  end

  @doc "Returns the immutable compiled patterns captured by a run, with a legacy fallback."
  def patterns_for_run(%SimulationRun{} = run, legacy_patterns \\ []) do
    case snapshot_value(run.input_snapshot || %{}, :patterns) do
      patterns when is_list(patterns) and patterns != [] -> patterns
      _ -> legacy_patterns
    end
  end

  def create_forecast_report(attrs),
    do: %ForecastReport{} |> ForecastReport.changeset(attrs) |> Repo.insert()

  def latest_run(%Study{id: study_id}), do: latest_run(study_id)

  def latest_run(study_id) do
    SimulationRun
    |> where([run], run.study_id == ^study_id and run.status == "completed")
    |> order_by([run], desc: run.completed_at, desc: run.id)
    |> limit(1)
    |> preload(:forecast_report)
    |> Repo.one()
  end

  def list_completed_runs(%Study{id: study_id}) do
    SimulationRun
    |> where([run], run.study_id == ^study_id and run.status == "completed")
    |> order_by([run], desc: run.completed_at, desc: run.id)
    |> preload(:scenario)
    |> Repo.all()
  end

  @doc """
  Finds the newest completed variant run with a completed run for its direct
  base scenario. This keeps the default comparison affordance meaningful when
  a study has several unrelated experiments.
  """
  def latest_comparable_pair(%Study{} = study) do
    completed_runs = list_completed_runs(study)

    Enum.find_value(completed_runs, fn variant_run ->
      case variant_run.scenario.variant_of_id do
        nil ->
          nil

        base_scenario_id ->
          case Enum.find(completed_runs, &(&1.scenario_id == base_scenario_id)) do
            nil -> nil
            base_run -> %{base_run: base_run, variant_run: variant_run}
          end
      end
    end)
  end

  def scenario_run_counts(%Study{id: study_id}) do
    SimulationRun
    |> where([run], run.study_id == ^study_id)
    |> group_by([run], run.scenario_id)
    |> select([run], {run.scenario_id, count(run.id)})
    |> Repo.all()
    |> Map.new()
  end

  def get_run!(%Study{} = study, run_id) do
    SimulationRun
    |> where([run], run.study_id == ^study.id and run.id == ^run_id)
    |> preload([:forecast_report, :scenario])
    |> Repo.one!()
  end

  def execute(study, scenario, context_pack, input, opts \\ %{}) do
    opts = opts |> Map.new() |> Map.put_new(:evidence_map, context_pack.source_mix || %{})
    prepared = SimulationRunner.prepare(input, study, opts)
    persist_prepared_run(study, scenario, context_pack, prepared)
  end

  @doc false
  def execute_queued_run(run_id) do
    with {:ok, run} <- mark_running(run_id),
         {:ok, input} <- restore_input(run.input_snapshot),
         prepared <- SimulationRunner.prepare(input, run.study, restore_opts(run)) do
      case complete_queued_run(run.id, prepared) do
        :noop -> :ok
        result -> result
      end
    else
      :noop -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Persists an aggregate run, its compact replay snapshots, and its forecast in
  one transaction. `prepared` should come from `SimulationRunner.prepare/3`.
  """
  def persist_prepared_run(
        %Study{} = study,
        %Scenario{} = scenario,
        %ContextPack{} = context_pack,
        prepared
      ) do
    Repo.transaction(fn ->
      run =
        prepared.run
        |> Map.merge(%{
          study_id: study.id,
          scenario_id: scenario.id,
          context_pack_id: context_pack.id
        })
        |> create_run!()

      Enum.each(prepared.snapshots, &add_snapshot!(run, &1))
      Enum.each(prepared.outcome_events, &add_outcome_event!(run, &1))

      report =
        prepared.forecast
        |> Map.merge(%{run_id: run.id, study_id: study.id})
        |> create_forecast_report!()

      update_study_status!(study, "simulation_ready")

      %{run: run, report: report}
    end)
  end

  defp cancel_oban_jobs(run_id) do
    SimulationRunWorker
    |> Atom.to_string()
    |> then(fn worker_name ->
      Oban.Job
      |> where([job], job.worker == ^worker_name)
      |> where([job], fragment("? ->> 'run_id' = ?", job.args, ^to_string(run_id)))
      |> where([job], job.state in ["available", "scheduled", "retryable", "executing"])
      |> Repo.all()
    end)
    |> Enum.each(&Oban.cancel_job/1)
  end

  defp mark_running(run_id) do
    result =
      Repo.transaction(fn ->
        case lock_run(run_id, "running") do
          nil ->
            Repo.rollback(:run_not_found)

          %SimulationRun{status: "queued"} = run ->
            {:transitioned, transition_run!(run, "running", %{started_at: DateTime.utc_now()})}

          %SimulationRun{status: "running"} = run ->
            {:existing, run}

          %SimulationRun{} ->
            :noop
        end
      end)

    case result do
      {:ok, {:transitioned, updated}} ->
        Notifications.broadcast(updated.study_id, %{
          kind: "simulation",
          status: "running",
          run_id: updated.id
        })

        {:ok, updated}

      {:ok, {:existing, run}} ->
        {:ok, run}

      {:ok, :noop} ->
        :noop

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_input(snapshot) when map_size(snapshot) == 0, do: {:error, :missing_input_snapshot}
  defp restore_input(snapshot), do: {:ok, SimulationRunner.restore_input(snapshot)}

  defp restore_opts(run) do
    options = run.execution_options || %{}

    %{
      mode: options["mode"] || run.mode,
      confidence: options["confidence"] || run.confidence || 0.6,
      budget_cap_usd: options["budget_cap_usd"],
      assumptions: restore_assumptions(options["assumptions"] || []),
      evidence_map: options["evidence_map"] || %{},
      coverage: options["coverage"] || %{}
    }
  end

  defp restore_assumptions(assumptions) do
    Enum.map(assumptions, fn
      %{"statement" => statement} when is_binary(statement) -> statement
      %{statement: statement} when is_binary(statement) -> statement
      statement when is_binary(statement) -> statement
      assumption -> inspect(assumption)
    end)
  end

  @doc false
  def complete_queued_run(run_id, prepared) do
    result =
      Repo.transaction(fn ->
        case lock_run(run_id, "completed") do
          nil ->
            Repo.rollback(:run_not_found)

          %SimulationRun{status: "running"} = run ->
            unless Costing.within_cap?(
                     prepared.run.actual_cost_usd || 0,
                     run.budget_cap_usd || 0
                   ) do
              Repo.rollback(:budget_cap_exceeded)
            end

            completed_run =
              transition_run!(run, "completed", %{
                actual_cost_usd: prepared.run.actual_cost_usd,
                decision_counts: prepared.run.decision_counts,
                aggregate_metrics: prepared.run.aggregate_metrics,
                completed_at: prepared.run.completed_at
              })

            Enum.each(prepared.snapshots, &add_snapshot!(completed_run, &1))
            Enum.each(prepared.outcome_events, &add_outcome_event!(completed_run, &1))

            report =
              prepared.forecast
              |> Map.merge(%{run_id: completed_run.id, study_id: completed_run.study_id})
              |> create_forecast_report!()

            update_study_status!(run.study, "simulation_ready")
            %{run: completed_run, report: report}

          %SimulationRun{status: status}
          when status in ["completed", "failed", "cancelled"] ->
            Repo.rollback(:noop)

          %SimulationRun{status: status} ->
            Repo.rollback({:invalid_run_transition, status, "completed"})
        end
      end)

    case result do
      {:ok, %{run: run}} = completed ->
        Notifications.broadcast(run.study_id, %{
          kind: "simulation",
          status: "completed",
          run_id: run.id
        })

        completed

      {:error, :noop} ->
        :noop

      other ->
        other
    end
  end

  defp lock_run(run_id, target_status, study_id \\ nil) do
    query = from(run in SimulationRun, where: run.id == ^run_id)

    query =
      if study_id,
        do: where(query, [run], run.study_id == ^study_id),
        else: query

    query
    |> lock("FOR UPDATE")
    |> preload([:study, :scenario, :context_pack])
    |> Repo.one()
    |> tap(fn
      %SimulationRun{} = run ->
        :telemetry.execute(
          @transition_lock_event,
          %{system_time: System.system_time()},
          %{run_id: run.id, from: run.status, target: target_status}
        )

      nil ->
        :ok
    end)
  end

  defp transition_run!(%SimulationRun{} = run, target_status, attrs \\ %{}) do
    if target_status in Map.fetch!(@valid_run_transitions, run.status) do
      run
      |> SimulationRun.changeset(Map.put(attrs, :status, target_status))
      |> update_or_rollback!()
    else
      Repo.rollback({:invalid_run_transition, run.status, target_status})
    end
  end

  defp create_run!(attrs) do
    case create_run(attrs) do
      {:ok, run} -> run
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp add_snapshot!(run, attrs) do
    case add_snapshot(run, attrs) do
      {:ok, snapshot} -> snapshot
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp add_outcome_event!(run, attrs) do
    case add_outcome_event(run, attrs) do
      {:ok, event} -> event
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp create_forecast_report!(attrs) do
    case create_forecast_report(attrs) do
      {:ok, report} -> report
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_or_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_study_status!(study, status) do
    case Study.changeset(study, %{status: status}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp get_scenario(study, scenario_id) do
    Scenario
    |> where([scenario], scenario.study_id == ^study.id and scenario.id == ^scenario_id)
    |> Repo.one()
  end

  defp scenario_has_runs?(scenario) do
    SimulationRun
    |> where([run], run.scenario_id == ^scenario.id)
    |> select([run], count(run.id))
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp control_first_events([]) do
    [
      %{
        "day" => "1",
        "title" => "Opt-in visibility framing",
        "impact" => "Control is explicit before visibility becomes relevant."
      }
    ]
  end

  defp control_first_events([first | rest]) do
    first = Map.new(first)

    [
      Map.merge(first, %{
        "title" => "Opt-in visibility framing",
        "impact" => "Control is explicit before visibility becomes relevant."
      })
      | rest
    ]
  end

  defp comparison_recommendation(variant, deltas) do
    counterfactual? =
      Map.get(variant.scenario.metadata || %{}, "created_as_counterfactual", false)

    resistance = deltas["resist"] || 0.0
    adoption = deltas["adopt"] || 0.0

    cond do
      resistance < 0 and adoption >= 0 ->
        %{
          tone: "validate",
          label: "Directional next step",
          headline: "Validate the variant before wider rollout.",
          body:
            "It reduces modeled resistance without lowering modeled adoption. Treat this as a testable forecast, then compare it with a real pilot.",
          disclosure: counterfactual_disclosure(counterfactual?)
        }

      resistance < 0 ->
        %{
          tone: "mixed",
          label: "Trade-off to validate",
          headline: "The variant reduces resistance, but the outcome is mixed.",
          body:
            "Resistance moves down while another modeled outcome moves in the opposite direction. Validate the timeline and framing before choosing between these scenarios.",
          disclosure: counterfactual_disclosure(counterfactual?)
        }

      adoption > 0 ->
        %{
          tone: "mixed",
          label: "Directional next step",
          headline: "The variant raises modeled adoption without reducing resistance.",
          body:
            "It may improve uptake, but the underlying resistance signal remains. Validate both measures in the same pilot rather than optimizing only for adoption.",
          disclosure: counterfactual_disclosure(counterfactual?)
        }

      true ->
        %{
          tone: "neutral",
          label: "No clear advantage",
          headline: "Neither scenario has a clear modeled advantage yet.",
          body:
            "The recorded changes do not produce a decisive directional signal. Add evidence, revise the mechanism, or test a sharper counterfactual.",
          disclosure: counterfactual_disclosure(counterfactual?)
        }
    end
  end

  defp counterfactual_disclosure(true),
    do:
      "This variant includes an explicit counterfactual assumption; it is a hypothesis, not evidence."

  defp counterfactual_disclosure(false),
    do: "These are aggregate model outputs, not observed real-world outcomes."

  defp snapshot_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp snapshot_value(_value, _key), do: nil
end
