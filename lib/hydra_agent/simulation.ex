defmodule HydraAgent.Simulation do
  @moduledoc """
  Workspace-scoped simulation runtime.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.{Budgets, Repo, Safety}
  alias HydraAgent.Runtime.PubSub
  alias HydraAgent.Simulation.Config
  alias HydraAgent.Simulation.Engine.Runner
  alias HydraAgent.Simulation.Supervisor, as: SimulationSupervisor

  alias HydraAgent.Simulation.{AgentProfile, BudgetReservation, Event, Report, Tick}
  alias HydraAgent.Simulation.Simulation, as: SimulationRecord
  @reportable_statuses ~w(completed budget_blocked failed canceled)
  @terminal_statuses ~w(completed budget_blocked failed canceled)
  @lease_timeout_seconds 60
  @recovery_limit 3
  @default_max_concurrent_simulations 5

  def list_simulations(workspace_id, opts \\ []) do
    SimulationRecord
    |> where([sim], sim.workspace_id == ^workspace_id)
    |> maybe_filter_status(opt(opts, :status))
    |> maybe_filter_query(opt(opts, :query) || opt(opts, :q))
    |> order_by([sim], desc: sim.inserted_at)
    |> maybe_offset(opt(opts, :offset))
    |> limit(^list_limit(opts))
    |> Repo.all()
    |> Repo.preload(reports: report_query())
  end

  def get_simulation!(id) do
    SimulationRecord
    |> Repo.get!(id)
    |> Repo.preload(simulation_preloads())
  end

  def get_simulation_for_workspace!(workspace_id, id) do
    SimulationRecord
    |> where(
      [sim],
      sim.workspace_id == ^normalize_id(workspace_id) and sim.id == ^normalize_id(id)
    )
    |> Repo.one!()
    |> Repo.preload(simulation_preloads())
  end

  def fetch_simulation_for_workspace(workspace_id, id) do
    with {:ok, workspace_id} <- parse_id(workspace_id, "workspace_id"),
         {:ok, id} <- parse_id(id, "simulation_id") do
      simulation =
        SimulationRecord
        |> where([sim], sim.workspace_id == ^workspace_id and sim.id == ^id)
        |> Repo.one()

      case simulation do
        nil -> {:error, %{"reason" => "simulation_not_found"}}
        simulation -> {:ok, Repo.preload(simulation, simulation_preloads())}
      end
    end
  end

  def estimate(attrs) do
    attrs
    |> Map.get("config", Map.get(attrs, :config, attrs))
    |> Config.estimate()
  end

  def create_simulation(attrs) do
    attrs = stringify_keys(attrs)
    config_attrs = attrs["config"] || %{}

    with {:ok, config} <- Config.validate(config_attrs),
         :ok <-
           check_preflight_budget(attrs["workspace_id"], attrs["supervisor_agent_id"], config) do
      estimate = Config.estimate(config)

      attrs =
        attrs
        |> Map.put("config", config)
        |> Map.put("budget_plan", estimate)
        |> Map.put_new("budget_usage", %{})
        |> Map.put_new("status", "configuring")

      Multi.new()
      |> Multi.insert(:simulation, SimulationRecord.changeset(%SimulationRecord{}, attrs))
      |> Multi.run(:reservation, fn repo, %{simulation: simulation} ->
        Budgets.reserve_simulation_budget(repo, simulation, estimate)
      end)
      |> Multi.run(:profiles, fn _repo, %{simulation: simulation} ->
        create_initial_profiles(simulation, config)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{simulation: simulation}} ->
          simulation = get_simulation!(simulation.id)
          audit(simulation, "simulation.create", "Simulation created", "info")
          {:ok, simulation}

        {:error, _operation, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  def create_agent_profile(%SimulationRecord{} = simulation, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("simulation_id", simulation.id)

    %AgentProfile{} |> AgentProfile.changeset(attrs) |> Repo.insert()
  end

  def update_agent_profile(%AgentProfile{} = profile, attrs) do
    profile |> AgentProfile.changeset(attrs) |> Repo.update()
  end

  def start_simulation(%SimulationRecord{} = simulation, opts \\ []) do
    lease_id = Ecto.UUID.generate()

    with {:ok, simulation} <- reload_simulation(simulation),
         :ok <- ensure_startable(simulation),
         {:ok, running} <-
           transition(
             simulation,
             "running",
             lease_attrs(
               lease_id,
               lease_owner(),
               Map.put(%{"started_at" => now()}, "completed_at", nil)
             ),
             ["configuring", "paused"]
           ) do
      case maybe_start_worker(running, Keyword.put(opts, :lease_id, lease_id)) do
        :ok ->
          running = get_simulation!(running.id)
          audit(running, "simulation.start", "Simulation started", "info")
          telemetry([:simulation, :start], %{count: 1}, telemetry_metadata(running))
          {:ok, running}

        {:error, reason} ->
          fail_simulation(running, reason)
          {:error, %{"reason" => "simulation_worker_start_failed", "error" => inspect(reason)}}
      end
    end
  end

  def run_to_completion(%SimulationRecord{} = simulation, opts \\ []) do
    with {:ok, running} <- start_simulation(simulation, async: false) do
      Runner.run(running.id, opts)
      {:ok, get_simulation!(running.id)}
    end
  end

  def pause_simulation(%SimulationRecord{} = simulation) do
    with {:ok, simulation} <- reload_simulation(simulation),
         :ok <- ensure_pausable(simulation) do
      SimulationSupervisor.stop_worker(simulation.id)

      simulation
      |> transition("paused", clear_lease_attrs(), ["running"])
      |> tap_transition("simulation.pause", "Simulation paused", "info")
    end
  end

  def resume_simulation(%SimulationRecord{} = simulation), do: start_simulation(simulation)

  def cancel_simulation(%SimulationRecord{} = simulation) do
    with {:ok, simulation} <- reload_simulation(simulation),
         :ok <- ensure_cancelable(simulation) do
      SimulationSupervisor.stop_worker(simulation.id)

      simulation
      |> transition("canceled", Map.merge(%{"completed_at" => now()}, clear_lease_attrs()), [
        "configuring",
        "running",
        "paused"
      ])
      |> tap_transition("simulation.cancel", "Simulation canceled", "warning")
    end
  end

  def worker_status(%SimulationRecord{} = simulation),
    do: SimulationSupervisor.worker_status(simulation.id)

  def heartbeat_simulation(simulation_id, lease_id) do
    now = now()

    SimulationRecord
    |> where([sim], sim.id == ^simulation_id and sim.lease_id == ^lease_id)
    |> Repo.update_all(
      set: [
        last_heartbeat_at: now,
        lease_expires_at: DateTime.add(now, @lease_timeout_seconds, :second),
        updated_at: now
      ]
    )
    |> case do
      {1, _rows} -> :ok
      _other -> {:error, :lease_not_current}
    end
  end

  def recover_running_simulations(opts \\ []) do
    now = now()
    limit = Keyword.get(opts, :limit, 25)

    SimulationRecord
    |> where([sim], sim.status == "running")
    |> where(
      [sim],
      is_nil(sim.lease_expires_at) or sim.lease_expires_at < ^now or
        is_nil(sim.last_heartbeat_at)
    )
    |> order_by([sim], asc: sim.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&recover_running_simulation/1)
  end

  def recover_running_simulation(%SimulationRecord{} = simulation) do
    case SimulationSupervisor.worker_status(simulation.id) do
      %{active: true} ->
        {:ok, :already_active}

      %{active: false} ->
        if simulation.recovery_count >= @recovery_limit do
          fail_simulation(simulation, :recovery_limit_exceeded)
        else
          simulation
          |> SimulationRecord.changeset(
            Map.merge(
              %{"recovery_count" => simulation.recovery_count + 1, "status" => "paused"},
              clear_lease_attrs()
            )
          )
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              audit(updated, "simulation.recover", "Simulation worker recovered", "warning")

              telemetry(
                [:simulation, :worker, :recover],
                %{count: 1},
                telemetry_metadata(updated)
              )

              start_simulation(updated)

            error ->
              error
          end
        end
    end
  end

  def complete_simulation(%SimulationRecord{} = simulation) do
    simulation
    |> transition("completed", Map.merge(%{"completed_at" => now()}, clear_lease_attrs()), [
      "running"
    ])
    |> tap_transition("simulation.complete", "Simulation completed", "info")
  end

  def fail_simulation(%SimulationRecord{} = simulation, error) do
    simulation
    |> transition(
      "failed",
      %{
        "completed_at" => now(),
        "budget_usage" => Map.put(simulation.budget_usage || %{}, "error", inspect(error))
      }
      |> Map.merge(clear_lease_attrs()),
      ["running"]
    )
    |> tap_transition("simulation.fail", "Simulation failed", "critical")
  end

  def block_for_budget(%SimulationRecord{} = simulation, reason) do
    case transition(
           simulation,
           "budget_blocked",
           %{
             "completed_at" => now(),
             "budget_usage" => Map.put(simulation.budget_usage || %{}, "blocked_reason", reason)
           }
           |> Map.merge(clear_lease_attrs()),
           ["running"]
         ) do
      {:ok, blocked} ->
        audit(blocked, "simulation.budget_block", "Simulation blocked by budget", "warning", %{
          "reason" => reason
        })

        telemetry([:simulation, :budget, :block], %{count: 1}, telemetry_metadata(blocked))
        blocked

      {:error, _error} ->
        get_simulation!(simulation.id)
    end
  end

  def record_tick(%SimulationRecord{} = simulation, attrs) do
    attrs = stringify_keys(attrs)
    event_attrs = attrs["events"] || []
    profile_states = attrs["profile_states"] || %{}
    tick_number = attrs["tick_number"]
    downgraded_count = attrs["downgraded_count"] || 0
    skipped_llm_count = attrs["skipped_llm_count"] || 0

    case Repo.get_by(Tick, simulation_id: simulation.id, tick_number: tick_number) do
      %Tick{} = tick ->
        {:ok, tick}

      nil ->
        Multi.new()
        |> Multi.run(:simulation_state, fn repo, _changes ->
          lock_recordable_simulation(repo, simulation.id)
        end)
        |> Multi.insert(
          :tick,
          Tick.changeset(%Tick{}, Map.put(attrs, "simulation_id", simulation.id))
        )
        |> Multi.insert_all(:events, Event, event_insert_rows(event_attrs))
        |> Multi.run(:profile_states, fn repo, _changes ->
          persist_final_states(repo, profile_states)
        end)
        |> Multi.run(:reservation, fn repo, %{tick: tick} ->
          Budgets.spend_simulation_reservation(simulation.id, tick.cost_cents, repo)
        end)
        |> Multi.update(:simulation, fn %{
                                          tick: tick,
                                          reservation: reservation,
                                          simulation_state: simulation
                                        } ->
          total_ticks = simulation.total_ticks + 1
          total_llm_calls = simulation.total_llm_calls + tick.llm_calls
          total_tokens = simulation.total_tokens_used + tick.tokens_used
          total_cost = simulation.total_cost_cents + tick.cost_cents

          SimulationRecord.changeset(simulation, %{
            "total_ticks" => total_ticks,
            "total_llm_calls" => total_llm_calls,
            "total_tokens_used" => total_tokens,
            "total_cost_cents" => total_cost,
            "budget_usage" =>
              budget_usage(
                simulation,
                total_ticks,
                total_llm_calls,
                total_tokens,
                total_cost,
                reservation,
                downgraded_count,
                skipped_llm_count
              ),
            "world_snapshot" => tick.world_delta
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{tick: tick, simulation: updated}} ->
            PubSub.broadcast_simulation_tick(updated, tick)

            telemetry(
              [:simulation, :tick, :stop],
              %{duration_us: tick.duration_us},
              telemetry_metadata(updated)
            )

            {:ok, tick}

          {:error, :tick, %Ecto.Changeset{} = changeset, _changes} ->
            case Repo.get_by(Tick, simulation_id: simulation.id, tick_number: tick_number) do
              %Tick{} = tick -> {:ok, tick}
              nil -> {:error, changeset}
            end

          {:error, _operation, error, _changes} ->
            {:error, error}
        end
    end
  end

  def generate_report(%SimulationRecord{} = simulation) do
    simulation = get_simulation!(simulation.id)

    if simulation.status in @reportable_statuses do
      summary = report_summary(simulation)

      content = """
      # #{simulation.title}

      Status: #{simulation.status}
      Ticks: #{simulation.total_ticks}
      LLM calls: #{simulation.total_llm_calls}
      Estimated cost: #{simulation.total_cost_cents} cents
      Downgraded decisions: #{summary["downgrade_summary"]["downgraded_count"]}

      Tier distribution:
      #{format_tiers(summary["tier_distribution"])}

      ## Key outcomes
      #{format_list(summary["key_outcomes"])}

      ## Risks discovered
      #{format_list(summary["risks_discovered"])}

      ## Recommended actions
      #{format_list(summary["recommended_actions"])}
      """

      %Report{}
      |> Report.changeset(%{
        "simulation_id" => simulation.id,
        "content" => String.trim(content),
        "statistical_summary" => summary,
        "generated_at" => now()
      })
      |> Repo.insert()
      |> tap(fn
        {:ok, _report} ->
          audit(simulation, "simulation.report", "Simulation report generated", "info")

          telemetry(
            [:simulation, :report, :generate],
            %{count: 1},
            telemetry_metadata(simulation)
          )

        _other ->
          :ok
      end)
    else
      {:error, %{"reason" => "simulation_not_reportable", "status" => simulation.status}}
    end
  end

  def replay(%SimulationRecord{} = simulation, opts \\ []) do
    simulation = get_simulation!(simulation.id)
    events = Enum.filter(simulation.events, &event_matches?(&1, opts))

    %{
      "simulation" => simulation_json(simulation),
      "ticks" => Enum.map(filter_ticks(simulation.ticks, opts), &tick_json/1),
      "events" => Enum.map(events, &event_json/1)
    }
  end

  def export(%SimulationRecord{} = simulation) do
    simulation = get_simulation!(simulation.id)
    audit(simulation, "simulation.export", "Simulation exported", "info")

    %{
      "simulation" => simulation_json(simulation),
      "agent_profiles" =>
        Enum.map(simulation.agent_profiles, fn profile ->
          %{
            id: profile.id,
            agent_key: profile.agent_key,
            persona: profile.persona,
            initial_beliefs: profile.initial_beliefs,
            initial_relationships: profile.initial_relationships,
            final_state: profile.final_state
          }
        end),
      "ticks" => Enum.map(simulation.ticks, &tick_json/1),
      "events" => Enum.map(simulation.events, &event_json/1),
      "reports" =>
        Enum.map(simulation.reports, fn report ->
          %{
            id: report.id,
            content: report.content,
            summary: report.statistical_summary,
            generated_at: report.generated_at
          }
        end),
      "budget_reservation" => reservation_json(loaded_reservation(simulation))
    }
  end

  def duplicate_simulation(%SimulationRecord{} = simulation, attrs \\ %{}) do
    simulation = get_simulation!(simulation.id)
    attrs = stringify_keys(attrs || %{})

    %{
      "workspace_id" => simulation.workspace_id,
      "supervisor_agent_id" => simulation.supervisor_agent_id,
      "run_id" => simulation.run_id,
      "title" => attrs["title"] || "#{simulation.title} copy",
      "goal" => attrs["goal"] || simulation.goal,
      "config" => Map.merge(simulation.config || %{}, attrs["config"] || %{}),
      "seed_material" => simulation.seed_material
    }
    |> create_simulation()
    |> tap(fn
      {:ok, copy} ->
        audit(copy, "simulation.duplicate", "Simulation duplicated", "info", %{
          "source_simulation_id" => simulation.id
        })

      _other ->
        :ok
    end)
  end

  def simulation_json(%SimulationRecord{} = simulation) do
    %{
      id: simulation.id,
      workspace_id: simulation.workspace_id,
      supervisor_agent_id: simulation.supervisor_agent_id,
      run_id: simulation.run_id,
      title: simulation.title,
      goal: simulation.goal,
      status: simulation.status,
      config: simulation.config,
      world_snapshot: simulation.world_snapshot,
      budget_plan: simulation.budget_plan,
      budget_usage: simulation.budget_usage,
      total_ticks: simulation.total_ticks,
      total_llm_calls: simulation.total_llm_calls,
      total_tokens_used: simulation.total_tokens_used,
      total_cost_cents: simulation.total_cost_cents,
      lease: lease_json(simulation),
      progress: progress_json(simulation),
      budget_reservation: reservation_json(loaded_reservation(simulation)),
      worker_status: SimulationSupervisor.worker_status(simulation.id),
      latest_report: latest_report_json(Map.get(simulation, :reports, [])),
      started_at: simulation.started_at,
      completed_at: simulation.completed_at,
      inserted_at: simulation.inserted_at,
      updated_at: simulation.updated_at
    }
  end

  def tick_json(%Tick{} = tick) do
    %{
      id: tick.id,
      tick_number: tick.tick_number,
      duration_us: tick.duration_us,
      tier_counts: tick.tier_counts,
      llm_calls: tick.llm_calls,
      tokens_used: tick.tokens_used,
      cost_cents: tick.cost_cents,
      world_delta: tick.world_delta
    }
  end

  def event_json(%Event{} = event) do
    %{
      id: event.id,
      tick: event.tick,
      event_type: event.event_type,
      source: event.source,
      target: event.target,
      description: event.description,
      properties: event.properties,
      stakes: event.stakes
    }
  end

  defp create_initial_profiles(simulation, config) do
    personas =
      case config["personas"] do
        list when is_list(list) ->
          Enum.map(list, &HydraAgent.Simulation.Agent.Persona.new/1)

        _other ->
          HydraAgent.Simulation.Agent.Persona.generated_population(
            config["agent_count"],
            config["rng_seed"] || simulation.id
          )
      end

    profiles =
      Enum.map(personas, fn persona ->
        key =
          persona.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        %{
          "simulation_id" => simulation.id,
          "agent_key" => key,
          "persona" => HydraAgent.Simulation.Agent.Persona.to_map(persona),
          "final_state" => %{"decision_count" => 0, "seen_categories" => %{}}
        }
      end)

    {count, _rows} =
      Repo.insert_all(AgentProfile, timestamp_rows(profiles),
        on_conflict: :nothing,
        conflict_target: [:simulation_id, :agent_key]
      )

    {:ok, count}
  end

  defp check_preflight_budget(workspace_id, agent_id, config) do
    estimate = Config.estimate(config)

    cond do
      estimate["estimated_cost_cents"] > config["max_budget_cents"] ->
        {:error,
         %{
           "reason" => "estimated_budget_exceeded",
           "estimated_cost_cents" => estimate["estimated_cost_cents"],
           "max_budget_cents" => config["max_budget_cents"]
         }}

      true ->
        Budgets.check_available(workspace_id,
          agent_id: agent_id,
          category: "simulation",
          estimated_tokens: estimate["estimated_tokens"],
          estimated_cost_cents: estimate["estimated_cost_cents"]
        )
    end
  end

  defp ensure_startable(%SimulationRecord{status: status} = simulation)
       when status in ["configuring", "paused"] do
    max_concurrent =
      Application.get_env(
        :hydra_agent,
        :max_concurrent_simulations,
        @default_max_concurrent_simulations
      )

    running =
      SimulationRecord
      |> where([sim], sim.workspace_id == ^simulation.workspace_id)
      |> where([sim], sim.status == "running")
      |> where([sim], sim.id != ^simulation.id)
      |> Repo.aggregate(:count)

    if running < max_concurrent do
      :ok
    else
      {:error,
       %{
         "reason" => "simulation_concurrency_limit_exceeded",
         "max_concurrent_simulations" => max_concurrent
       }}
    end
  end

  defp ensure_startable(%SimulationRecord{status: status}),
    do: {:error, %{"reason" => "simulation_not_startable", "status" => status}}

  defp ensure_pausable(%SimulationRecord{status: "running"}), do: :ok

  defp ensure_pausable(%SimulationRecord{status: status}),
    do: {:error, %{"reason" => "simulation_not_pausable", "status" => status}}

  defp ensure_cancelable(%SimulationRecord{status: status})
       when status in ["configuring", "running", "paused"],
       do: :ok

  defp ensure_cancelable(%SimulationRecord{status: status}),
    do: {:error, %{"reason" => "simulation_not_cancelable", "status" => status}}

  defp lock_recordable_simulation(repo, simulation_id) do
    simulation =
      SimulationRecord
      |> where([sim], sim.id == ^simulation_id)
      |> lock("FOR UPDATE")
      |> repo.one!()

    case simulation do
      %SimulationRecord{status: status} when status in @terminal_statuses ->
        {:error, %{"reason" => "simulation_terminal", "status" => status}}

      %SimulationRecord{} = simulation ->
        {:ok, simulation}
    end
  end

  defp reload_simulation(%SimulationRecord{} = simulation) do
    {:ok, Repo.get!(SimulationRecord, simulation.id) |> Repo.preload(simulation_preloads())}
  end

  defp maybe_start_worker(running, opts) do
    if Keyword.get(opts, :async, true) do
      case SimulationSupervisor.start_worker(running.id, opts) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp transition(%SimulationRecord{} = simulation, status, attrs, allowed_statuses) do
    simulation = Repo.get!(SimulationRecord, simulation.id)

    if transition_allowed?(simulation.status, allowed_statuses) do
      simulation
      |> SimulationRecord.changeset(Map.merge(attrs, %{"status" => status}))
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          if status in @terminal_statuses do
            Budgets.release_simulation_reservation(updated.id, status)
          end

          PubSub.broadcast_simulation(updated)
          {:ok, updated}

        error ->
          error
      end
    else
      {:error,
       %{
         "reason" => "simulation_transition_not_allowed",
         "status" => simulation.status,
         "target_status" => status
       }}
    end
  end

  defp transition_allowed?(_status, :any), do: true
  defp transition_allowed?(status, statuses), do: status in statuses

  defp tap_transition({:ok, %SimulationRecord{} = simulation} = result, action, summary, severity) do
    audit(simulation, action, summary, severity)
    telemetry([:simulation, :transition], %{count: 1}, telemetry_metadata(simulation))
    result
  end

  defp tap_transition(result, _action, _summary, _severity), do: result

  defp lease_attrs(lease_id, owner, attrs) do
    issued_at = now()

    Map.merge(attrs, %{
      "lease_id" => lease_id,
      "lease_owner" => owner,
      "lease_expires_at" => DateTime.add(issued_at, @lease_timeout_seconds, :second),
      "last_heartbeat_at" => issued_at
    })
  end

  defp clear_lease_attrs do
    %{
      "lease_id" => nil,
      "lease_owner" => nil,
      "lease_expires_at" => nil,
      "last_heartbeat_at" => nil
    }
  end

  defp lease_owner do
    "#{node()}:#{inspect(self())}"
  end

  defp audit(%SimulationRecord{} = simulation, action, summary, severity, metadata \\ %{}) do
    Safety.record_event(%{
      workspace_id: simulation.workspace_id,
      agent_id: simulation.supervisor_agent_id,
      run_id: simulation.run_id,
      category: "runtime",
      severity: severity,
      action: action,
      summary: summary,
      metadata:
        Map.merge(
          %{
            "simulation_id" => simulation.id,
            "status" => simulation.status
          },
          metadata
        )
    })

    :ok
  end

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:hydra_agent | event], measurements, metadata)
  end

  defp telemetry_metadata(%SimulationRecord{} = simulation) do
    %{
      workspace_id: simulation.workspace_id,
      simulation_id: simulation.id,
      status: simulation.status
    }
  end

  defp persist_final_states(_repo, states) when states in [%{}, nil], do: {:ok, 0}

  defp persist_final_states(repo, states) do
    count =
      Enum.reduce(states, 0, fn {profile_id, state}, acc ->
        profile = repo.get!(AgentProfile, profile_id)

        {:ok, _profile} =
          profile |> AgentProfile.changeset(%{"final_state" => state}) |> repo.update()

        acc + 1
      end)

    {:ok, count}
  end

  defp budget_usage(
         simulation,
         total_ticks,
         total_llm_calls,
         total_tokens,
         total_cost,
         reservation,
         downgraded_count,
         skipped_llm_count
       ) do
    reservation_usage =
      case reservation do
        %BudgetReservation{} = reservation ->
          %{
            "reserved_cost_cents" => reservation.reserved_cost_cents,
            "spent_cost_cents" => reservation.spent_cost_cents,
            "remaining_reserved_cost_cents" =>
              max(reservation.reserved_cost_cents - reservation.spent_cost_cents, 0),
            "reservation_status" => reservation.status
          }

        _other ->
          %{}
      end

    Map.merge(simulation.budget_usage || %{}, %{
      "total_ticks" => total_ticks,
      "total_llm_calls" => total_llm_calls,
      "total_tokens_used" => total_tokens,
      "total_cost_cents" => total_cost,
      "downgraded_count" =>
        (get_in(simulation.budget_usage || %{}, ["downgraded_count"]) || 0) + downgraded_count,
      "skipped_llm_count" =>
        (get_in(simulation.budget_usage || %{}, ["skipped_llm_count"]) || 0) +
          skipped_llm_count
    })
    |> Map.merge(reservation_usage)
  end

  defp lease_json(%SimulationRecord{} = simulation) do
    %{
      id: simulation.lease_id,
      owner: simulation.lease_owner,
      expires_at: simulation.lease_expires_at,
      last_heartbeat_at: simulation.last_heartbeat_at,
      recovery_count: simulation.recovery_count
    }
  end

  defp progress_json(%SimulationRecord{} = simulation) do
    max_ticks = get_in(simulation.config || %{}, ["max_ticks"]) || 0

    %{
      ticks_completed: simulation.total_ticks,
      max_ticks: max_ticks,
      ratio: if(max_ticks > 0, do: simulation.total_ticks / max_ticks, else: nil)
    }
  end

  defp reservation_json(%BudgetReservation{} = reservation) do
    %{
      id: reservation.id,
      status: reservation.status,
      estimated_tokens: reservation.estimated_tokens,
      estimated_cost_cents: reservation.estimated_cost_cents,
      reserved_cost_cents: reservation.reserved_cost_cents,
      spent_cost_cents: reservation.spent_cost_cents,
      remaining_cost_cents: max(reservation.reserved_cost_cents - reservation.spent_cost_cents, 0)
    }
  end

  defp reservation_json(_reservation), do: nil

  defp loaded_reservation(%SimulationRecord{} = simulation) do
    case Map.get(simulation, :budget_reservation) do
      %BudgetReservation{} = reservation -> reservation
      _other -> Repo.get_by(BudgetReservation, simulation_id: simulation.id)
    end
  end

  defp latest_report_json([%Report{} = report | _reports]) do
    %{id: report.id, generated_at: report.generated_at, summary: report.statistical_summary}
  end

  defp latest_report_json(_reports), do: nil

  defp filter_ticks(ticks, opts) do
    from = opt(opts, :tick_from)
    to = opt(opts, :tick_to)

    Enum.filter(ticks, fn tick ->
      (is_nil(from) or tick.tick_number >= normalize_filter_int(from)) and
        (is_nil(to) or tick.tick_number <= normalize_filter_int(to))
    end)
  end

  defp event_matches?(event, opts) do
    (is_nil(opt(opts, :tick_from)) or event.tick >= normalize_filter_int(opt(opts, :tick_from))) and
      (is_nil(opt(opts, :tick_to)) or event.tick <= normalize_filter_int(opt(opts, :tick_to))) and
      (is_nil(opt(opts, :event_type)) or event.event_type == opt(opts, :event_type)) and
      (is_nil(opt(opts, :source)) or event.source == opt(opts, :source)) and
      (is_nil(opt(opts, :method)) or
         get_in(event.properties || %{}, ["method"]) == opt(opts, :method))
  end

  defp normalize_filter_int(nil), do: nil
  defp normalize_filter_int(value) when is_integer(value), do: value

  defp normalize_filter_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp normalize_filter_int(_value), do: nil

  defp format_list([]), do: "- n/a"
  defp format_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp event_insert_rows([]), do: []
  defp event_insert_rows(events), do: timestamp_rows(events)

  defp timestamp_rows(rows) do
    now = now()

    Enum.map(rows, fn row ->
      row
      |> stringify_keys()
      |> atomize_known_keys()
      |> Map.put("inserted_at", now)
      |> Map.put("updated_at", now)
      |> atomize_known_keys()
    end)
  end

  defp atomize_known_keys(row) do
    Map.new(row, fn
      {key, value} when is_binary(key) ->
        {String.to_existing_atom(key), value}

      pair ->
        pair
    end)
  rescue
    ArgumentError ->
      row
  end

  defp report_summary(simulation) do
    tier_distribution =
      Enum.reduce(
        simulation.ticks,
        %{"routine" => 0, "emotional" => 0, "complex" => 0, "negotiation" => 0},
        fn tick, acc ->
          Map.merge(acc, tick.tier_counts || %{}, fn _key, left, right -> left + right end)
        end
      )

    actions =
      simulation.events
      |> Enum.filter(&(&1.event_type == "agent_action"))
      |> Enum.map(&(&1.properties || %{}))

    risks =
      simulation.events
      |> Enum.filter(&((&1.stakes || 0) >= 0.7))
      |> Enum.map(& &1.description)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(5)

    downgraded_count = Enum.count(actions, &Map.has_key?(&1, "downgraded_from"))

    skipped_count =
      Enum.count(actions, &(&1["method"] == "rules_engine" and &1["downgraded_from"]))

    %{
      "total_ticks" => simulation.total_ticks,
      "total_llm_calls" => simulation.total_llm_calls,
      "total_tokens_used" => simulation.total_tokens_used,
      "total_cost_cents" => simulation.total_cost_cents,
      "tier_distribution" => tier_distribution,
      "downgrade_summary" => %{
        "downgraded_count" => downgraded_count,
        "skipped_llm_count" => skipped_count
      },
      "budget_breakdown" => simulation.budget_usage || %{},
      "key_outcomes" => key_outcomes(simulation, actions),
      "surprising_behaviors" => surprising_behaviors(actions),
      "risks_discovered" => risks,
      "agent_contributions" => agent_contributions(actions),
      "recommended_actions" => recommended_actions(simulation, risks, downgraded_count)
    }
  end

  defp key_outcomes(simulation, actions) do
    [
      "#{simulation.total_ticks} ticks completed with #{length(actions)} recorded agent actions.",
      "#{simulation.total_llm_calls} LLM calls used #{simulation.total_tokens_used} tokens.",
      "Simulation ended with status #{simulation.status}."
    ]
  end

  defp surprising_behaviors(actions) do
    actions
    |> Enum.filter(
      &(&1["tier"] in ["complex", "negotiation"] or Map.has_key?(&1, "downgraded_from"))
    )
    |> Enum.map(fn action ->
      "#{action["agent_key"] || "agent"} chose #{action["action"] || "unknown"} via #{action["method"] || "unknown"}"
    end)
    |> Enum.take(5)
  end

  defp agent_contributions(actions) do
    actions
    |> Enum.group_by(&(&1["agent_key"] || "unknown"))
    |> Map.new(fn {agent_key, agent_actions} ->
      {agent_key,
       %{
         "action_count" => length(agent_actions),
         "llm_calls" =>
           Enum.count(agent_actions, &(&1["method"] in ["cheap_llm", "frontier_llm"])),
         "cost_cents" => Enum.sum(Enum.map(agent_actions, &(&1["cost_cents"] || 0)))
       }}
    end)
  end

  defp recommended_actions(simulation, risks, downgraded_count) do
    []
    |> maybe_recommend(
      simulation.status == "budget_blocked",
      "Increase budget or lower LLM escalation shares before rerun."
    )
    |> maybe_recommend(
      risks != [],
      "Review high-stakes events before acting on the simulation outcome."
    )
    |> maybe_recommend(
      downgraded_count > 0,
      "Inspect downgraded decisions to decide whether fidelity was sufficient."
    )
    |> case do
      [] -> ["Compare this run against a duplicated simulation with an alternate seed."]
      recommendations -> Enum.reverse(recommendations)
    end
  end

  defp maybe_recommend(recommendations, true, message), do: [message | recommendations]
  defp maybe_recommend(recommendations, false, _message), do: recommendations

  defp format_tiers(tiers) do
    tiers
    |> Enum.map_join("\n", fn {tier, count} -> "- #{tier}: #{count}" end)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [sim], sim.status == ^status)

  defp maybe_filter_query(query, value) when value in [nil, ""], do: query

  defp maybe_filter_query(query, value) do
    pattern = "%#{value}%"
    where(query, [sim], ilike(sim.title, ^pattern) or ilike(sim.goal, ^pattern))
  end

  defp maybe_offset(query, nil), do: query

  defp maybe_offset(query, offset) do
    offset(query, ^max(normalize_filter_int(offset) || 0, 0))
  end

  defp list_limit(opts) do
    opts
    |> opt(:limit)
    |> normalize_filter_int()
    |> case do
      nil -> 100
      limit -> limit |> max(1) |> min(250)
    end
  end

  defp simulation_preloads do
    [
      :agent_profiles,
      :budget_reservation,
      ticks: from(tick in Tick, order_by: [asc: tick.tick_number]),
      events: from(event in Event, order_by: [asc: event.tick, asc: event.id]),
      reports: report_query()
    ]
  end

  defp report_query, do: from(report in Report, order_by: [desc: report.inserted_at])

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp parse_id(nil, field), do: {:error, %{"reason" => "#{field}_required"}}
  defp parse_id(id, _field) when is_integer(id), do: {:ok, id}

  defp parse_id(id, field) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> {:error, %{"reason" => "#{field}_invalid"}}
    end
  end

  defp parse_id(_id, field), do: {:error, %{"reason" => "#{field}_invalid"}}

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
