defmodule HydraAgent.Simulation.Engine.Runner do
  @moduledoc """
  Durable simulation tick runner.
  """

  alias HydraAgent.Repo
  alias HydraAgent.Simulation
  alias HydraAgent.Simulation.Agent.Persona
  alias HydraAgent.Simulation.Engine.{BatchInference, SimAgent}
  alias HydraAgent.Simulation.World.Event

  def run(simulation_id, opts \\ []) do
    simulation_id
    |> Simulation.get_simulation!()
    |> run_loaded(opts)
  end

  def run_loaded(simulation, opts \\ []) do
    config = HydraAgent.Simulation.Config.normalize(simulation.config || %{})
    ensure_profiles(simulation, config)
    loop(simulation.id, config, opts)
  end

  defp loop(simulation_id, config, opts) do
    simulation = Simulation.get_simulation!(simulation_id)

    cond do
      simulation.status != "running" ->
        {:ok, simulation.status}

      wall_clock_exceeded?(simulation, config) ->
        Simulation.fail_simulation(simulation, :max_wall_clock_exceeded)

      simulation.total_ticks >= config["max_ticks"] ->
        Simulation.complete_simulation(simulation)

      true ->
        case execute_tick(simulation, config, opts) do
          {:ok, _tick} ->
            if config["tick_interval_ms"] > 0, do: Process.sleep(config["tick_interval_ms"])
            loop(simulation_id, config, opts)

          {:budget_blocked, blocked} ->
            {:ok, blocked}

          {:error, error} ->
            Simulation.fail_simulation(simulation, error)
        end
    end
  end

  def execute_tick(simulation, config, opts \\ []) do
    started = System.monotonic_time(:microsecond)
    simulation = Repo.preload(simulation, [:agent_profiles])
    budget_remaining = max(config["max_budget_cents"] - simulation.total_cost_cents, 0)

    cond do
      Simulation.get_simulation!(simulation.id).status != "running" ->
        {:ok, :halted}

      budget_remaining <= 0 ->
        {:budget_blocked, Simulation.block_for_budget(simulation, "simulation_budget_exhausted")}

      true ->
        tick_number = simulation.total_ticks
        events = Event.generate(tick_number, config)

        {routine_decisions, llm_requests, final_states} =
          decide(simulation.agent_profiles, events, config)

        if Simulation.get_simulation!(simulation.id).status != "running" do
          {:ok, :halted}
        else
          run_llm_and_record(
            simulation,
            config,
            opts,
            budget_remaining,
            started,
            tick_number,
            events,
            routine_decisions,
            llm_requests,
            final_states
          )
        end
    end
  end

  defp run_llm_and_record(
         simulation,
         config,
         opts,
         budget_remaining,
         started,
         tick_number,
         events,
         routine_decisions,
         llm_requests,
         final_states
       ) do
    llm_batch =
      BatchInference.run(
        llm_requests,
        %{
          workspace_id: simulation.workspace_id,
          agent_id: simulation.supervisor_agent_id,
          run_id: simulation.run_id,
          simulation_id: simulation.id
        },
        config,
        budget_remaining,
        opts
      )

    if Simulation.get_simulation!(simulation.id).status != "running" do
      {:ok, :halted}
    else
      decisions = routine_decisions ++ llm_batch.results
      final_states = apply_llm_states(final_states, events, llm_batch.results)

      duration_us = System.monotonic_time(:microsecond) - started
      tier_counts = tier_counts(decisions)
      world_delta = world_delta(simulation, tick_number, events, decisions, llm_batch)

      Simulation.record_tick(simulation, %{
        "tick_number" => tick_number,
        "duration_us" => duration_us,
        "tier_counts" => tier_counts,
        "llm_calls" => llm_batch.llm_calls,
        "tokens_used" => llm_batch.tokens_used,
        "cost_cents" => llm_batch.cost_cents,
        "world_delta" => world_delta,
        "events" => event_attrs(simulation.id, events, decisions),
        "profile_states" => final_states,
        "downgraded_count" => llm_batch.downgraded_count,
        "skipped_llm_count" => llm_batch.skipped_llm_count
      })
      |> case do
        {:ok, tick} ->
          if llm_batch.budget_exceeded? do
            blocked =
              simulation.id
              |> Simulation.get_simulation!()
              |> Simulation.block_for_budget("actual_provider_cost_exceeded_simulation_budget")

            {:budget_blocked, blocked}
          else
            {:ok, tick}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_profiles(simulation, config) do
    simulation = Repo.preload(simulation, [:agent_profiles])

    if simulation.agent_profiles == [] do
      personas =
        case config["personas"] do
          list when is_list(list) ->
            Enum.map(list, &Persona.new/1)

          _other ->
            Persona.generated_population(
              config["agent_count"],
              config["rng_seed"] || simulation.id
            )
        end

      Enum.each(personas, fn persona ->
        key =
          persona.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        Simulation.create_agent_profile(simulation, %{
          "agent_key" => key,
          "persona" => Persona.to_map(persona),
          "final_state" => %{"decision_count" => 0, "seen_categories" => %{}}
        })
      end)
    end
  end

  defp decide(profiles, events, config) do
    Enum.reduce(profiles, {[], [], %{}}, fn profile, acc ->
      persona = Persona.new(profile.persona || %{})
      state = profile.final_state || %{}

      Enum.reduce(events, acc, fn event, {routine, llm, states} ->
        case SimAgent.decide(persona, event, state, config) do
          {:ok, decision, _state} ->
            decision = Map.put(decision, "agent_key", profile.agent_key)
            next_state = SimAgent.apply_decision_state(state, event, decision)
            {[decision | routine], llm, Map.put(states, profile.id, next_state)}

          {:llm, tier, req, _state} ->
            req =
              Map.merge(req, %{
                agent_key: profile.agent_key,
                profile_id: profile.id,
                current_cost_cents: Map.get(state, "cost_cents", 0)
              })

            {routine, [%{req | tier: tier} | llm], Map.put_new(states, profile.id, state)}
        end
      end)
    end)
    |> then(fn {routine, llm, states} -> {Enum.reverse(routine), Enum.reverse(llm), states} end)
  end

  defp apply_llm_states(states, [], _decisions), do: states

  defp apply_llm_states(states, [event | _events], decisions) do
    Enum.reduce(decisions, states, fn decision, acc ->
      case decision["profile_id"] do
        nil ->
          acc

        profile_id ->
          state = Map.get(acc, profile_id, %{})

          next_state =
            state
            |> SimAgent.apply_decision_state(event, decision)
            |> Map.update(
              "cost_cents",
              decision["cost_cents"] || 0,
              &(&1 + (decision["cost_cents"] || 0))
            )
            |> Map.update("llm_calls", llm_call_count(decision), &(&1 + llm_call_count(decision)))

          Map.put(acc, profile_id, next_state)
      end
    end)
  end

  defp llm_call_count(%{"method" => method}) when method in ["cheap_llm", "frontier_llm"], do: 1
  defp llm_call_count(_decision), do: 0

  defp tier_counts(decisions) do
    base = %{"routine" => 0, "emotional" => 0, "complex" => 0, "negotiation" => 0}

    Enum.reduce(decisions, base, fn decision, acc ->
      key =
        case decision["tier"] do
          "cheap" -> "complex"
          "frontier" -> "negotiation"
          tier when tier in ["routine", "emotional", "complex", "negotiation"] -> tier
          _ -> "routine"
        end

      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp world_delta(simulation, tick_number, events, decisions, batch) do
    simulation.world_snapshot
    |> Event.evolve_world(tick_number, events, decisions)
    |> Map.put("tick_summary", %{
      "tick" => tick_number,
      "event_count" => length(events),
      "action_count" => length(decisions),
      "llm_calls" => batch.llm_calls,
      "downgraded_count" => batch.downgraded_count,
      "skipped_llm_count" => batch.skipped_llm_count
    })
    |> Map.put("actions", Enum.take(decisions, 50))
  end

  defp wall_clock_exceeded?(simulation, config) do
    max_seconds = config["max_wall_clock_seconds"]

    max_seconds && simulation.started_at &&
      DateTime.diff(DateTime.utc_now(), simulation.started_at, :second) > max_seconds
  end

  defp event_attrs(simulation_id, events, decisions) do
    world_events =
      Enum.map(events, fn event ->
        %{
          "simulation_id" => simulation_id,
          "tick" => event.tick,
          "event_type" => Atom.to_string(event.type),
          "source" => source(event.source),
          "target" => source(event.target),
          "description" => event.description,
          "stakes" => event.stakes,
          "properties" => normalize_properties(Map.from_struct(event))
        }
      end)

    action_events =
      Enum.map(decisions, fn decision ->
        %{
          "simulation_id" => simulation_id,
          "tick" => List.first(events, %{tick: 0}).tick,
          "event_type" => "agent_action",
          "source" => decision["agent_key"],
          "description" => decision["action"],
          "properties" => decision
        }
      end)

    world_events ++ action_events
  end

  defp source(nil), do: nil
  defp source(value) when is_atom(value), do: Atom.to_string(value)
  defp source({left, right}), do: "#{source(left)}:#{source(right)}"
  defp source(value), do: to_string(value)

  defp normalize_properties(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value({left, right}), do: [normalize_value(left), normalize_value(right)]
  defp normalize_value(value) when is_map(value), do: normalize_properties(value)
  defp normalize_value(value), do: value
end
