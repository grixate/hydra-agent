defmodule HydraAgent.Simulations.Engine.QuickEngine do
  @moduledoc """
  Versioned deterministic round executor for Quick mode.

  The engine is provider-free. Authoritative resource mutations are delegated
  to the Decimal Resource Ledger and every merge happens in stable ID order.
  """

  alias HydraAgent.Simulations.ContentHash
  alias HydraAgent.Simulations.Engine.EventRecorder.Event
  alias HydraAgent.Simulations.Engine.ResourceLedger

  @recent_event_limit 500

  def initial_state(compiled, script) do
    %{
      "round" => 0,
      "world" => get_in(script, ["world", "state"]) || %{},
      "agents" => Enum.sort_by(compiled.agents, & &1["id"]),
      "relationships" => Enum.sort_by(compiled.relationships, & &1["id"]),
      "action_counts" => %{},
      "observations" => [],
      "recent_events" => [],
      "unchanged_rounds" => 0,
      "stop_reason" => nil
    }
  end

  def run_round(run_record_id, state, script, round, seed),
    do: run_round(run_record_id, state, script, round, seed, %{})

  def run_round(run_record_id, state, script, round, seed, decision_actions)
      when is_map(decision_actions) do
    state = Map.put(state, "round_events", [])

    with hydrated <- ResourceLedger.hydrate_agents(run_record_id, state["agents"]),
         state = Map.put(state, "agents", hydrated),
         {:ok, state, before_events, before_transactions, before_changes} <-
           apply_scheduled_events(run_record_id, state, script, round, "before_actions"),
         {:ok, state, action_events, action_transactions, action_changes} <-
           resolve_actions(run_record_id, state, script, round, seed, decision_actions),
         {:ok, state, after_events, after_transactions, after_changes} <-
           apply_scheduled_events(run_record_id, state, script, round, "after_actions"),
         {:ok, state, transition_events, transition_transactions, transition_changes} <-
           apply_transitions(run_record_id, state, script, round),
         state <-
           ResourceLedger.hydrate_agents(run_record_id, state["agents"])
           |> then(&Map.put(state, "agents", &1)),
         state <- Map.delete(state, "round_events"),
         observation <- observe(run_record_id, script, state),
         state_changes <- before_changes + action_changes + after_changes + transition_changes do
      unchanged_rounds = if state_changes == 0, do: state["unchanged_rounds"] + 1, else: 0
      observations = state["observations"] ++ [%{"round" => round, "metrics" => observation}]
      world = Map.put(state["world"], "current_round", round)

      state =
        state
        |> Map.put("round", round)
        |> Map.put("world", world)
        |> Map.put("observations", observations)
        |> Map.put("unchanged_rounds", unchanged_rounds)
        |> Map.put("stop_reason", stopping_reason(script, round, observation, unchanged_rounds))

      events =
        [
          %Event{
            type: "simulation.round.started",
            phase: "before_actions",
            summary: "Round #{round} started",
            payload: %{"round" => round},
            provenance: provenance(script)
          }
        ] ++
          before_events ++
          action_events ++
          after_events ++
          transition_events ++
          [
            %Event{
              type: "simulation.observation",
              phase: "observations",
              summary: "Round #{round} observations recorded",
              payload: %{"metrics" => observation},
              provenance: provenance(script)
            },
            %Event{
              type: "simulation.round.completed",
              phase: "observations",
              summary: "Round #{round} committed",
              payload: %{
                "round" => round,
                "state_changes" => state_changes,
                "unchanged_rounds" => unchanged_rounds,
                "stop_reason" => state["stop_reason"]
              },
              provenance: provenance(script)
            }
          ]

      {:ok,
       %{
         state: state,
         events: events,
         transactions:
           before_transactions ++
             action_transactions ++ after_transactions ++ transition_transactions,
         state_changes: state_changes
       }}
    end
  end

  def result_payload(state, run_record) do
    %{
      "engine_version" => run_record.engine_version,
      "pack_hash" => run_record.pack_hash,
      "seed" => run_record.seed,
      "rounds_completed" => state["round"],
      "population_size" => length(state["agents"]),
      "model_calls" => run_record.model_call_count,
      "stop_reason" => state["stop_reason"] || "final_round",
      "world" => state["world"],
      "agents" => state["agents"],
      "resource_balances" => ResourceLedger.balances(run_record.id),
      "relationships_hash" => ContentHash.digest(state["relationships"]),
      "action_counts" => state["action_counts"],
      "observations" => state["observations"]
    }
  end

  defp apply_scheduled_events(run_record_id, state, script, round, phase) do
    script
    |> Map.get("events", [])
    |> Enum.filter(&(&1["at_round"] == round and &1["phase"] == phase))
    |> Enum.sort_by(&{Map.get(&1, "priority", 0), &1["id"]})
    |> Enum.reduce_while({:ok, state, [], [], 0}, fn event,
                                                     {:ok, current, events, transactions, changes} ->
      indices = audience_indices(current["agents"], event["audience"] || %{})

      case apply_effects(current, event["effects"] || [], indices, nil, round, phase, event["id"]) do
        {:ok, next, operations, effect_changes} ->
          case apply_resource_operations(run_record_id, operations) do
            {:ok, applied} ->
              emitted = %Event{
                type: "simulation.world_event",
                phase: phase,
                summary: "Scheduled event #{event["id"]} applied",
                targets: sampled_targets(next["agents"], indices),
                payload: %{
                  "event_id" => event["id"],
                  "target_count" => length(indices),
                  "effect_count" => length(event["effects"] || [])
                },
                source_ref: "event:#{event["id"]}",
                provenance: provenance(script)
              }

              event_context = round_event(event, round)
              recent = [event_context | next["recent_events"]]

              next =
                next
                |> Map.put("recent_events", Enum.take(recent, @recent_event_limit))
                |> Map.update("round_events", [event_context], &(&1 ++ [event_context]))

              {:cont,
               {:ok, next, events ++ [emitted], transactions ++ applied, changes + effect_changes}}

            {:error, reason} ->
              {:halt, {:error, {:resource_ledger_inconsistency, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_actions(run_record_id, state, script, round, seed, decision_actions) do
    assignments = Map.new(script["agent_types"] || [], &{&1["id"], &1["policy"]})
    policies = Map.new(script["policies"] || [], &{&1["id"], &1})
    actions = Map.new(script["actions"] || [], &{&1["id"], &1})

    initial = %{
      agents: [],
      operations: [],
      deferred: %{},
      choices: [],
      emitted: [],
      changes: 0,
      blocked: %{}
    }

    resolved =
      state["agents"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce(initial, fn agent, acc ->
        facts = facts(agent, state["world"])
        decision = decision_actions[agent["id"]]

        with {:ok, action_id} <-
               choose_action_with_decision(
                 decision,
                 assignments[agent["type"]],
                 policies,
                 facts,
                 seed,
                 round,
                 agent["id"]
               ),
             %{} = action <- actions[action_id],
             true <- agent["type"] in (action["actors"] || []),
             true <- condition_true?(action["preconditions"], facts),
             true <- can_pay?(agent, action["costs"] || []),
             {:ok, next_agent, operations, deferred, changes} <-
               apply_agent_action(state, agent, action, round) do
          next_agent = apply_memory_updates(next_agent, decision)

          emissions =
            Enum.map(action["emits"] || [], fn emission ->
              %{
                "type" => emission["type"],
                "payload" => emission["payload"] || %{},
                "actor" => agent["id"],
                "action" => action_id,
                "round" => round
              }
            end)

          %{
            acc
            | agents: [next_agent | acc.agents],
              operations: Enum.reverse(operations, acc.operations),
              deferred: add_deferred(acc.deferred, action_id, agent["id"], deferred),
              choices: [{agent["id"], action_id} | acc.choices],
              emitted: emissions ++ acc.emitted,
              changes: acc.changes + changes
          }
        else
          reason ->
            code = blocked_reason(reason)

            %{
              acc
              | agents: [agent | acc.agents],
                blocked: Map.update(acc.blocked, code, 1, &(&1 + 1))
            }
        end
      end)

    next =
      state
      |> Map.put("agents", Enum.reverse(resolved.agents))

    with {:ok, next, deferred_operations, deferred_changes} <-
           apply_deferred_effects(next, resolved.deferred, round),
         {:ok, applied} <-
           apply_resource_operations(
             run_record_id,
             Enum.reverse(resolved.operations) ++ deferred_operations
           ) do
      choices = Enum.reverse(resolved.choices)
      counts = Enum.frequencies_by(choices, &elem(&1, 1))

      action_counts =
        Map.merge(state["action_counts"], counts, fn _action, previous, current ->
          previous + current
        end)

      action_events =
        counts
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {action_id, count} ->
          target_ids =
            choices
            |> Enum.flat_map(fn {agent_id, selected} ->
              if selected == action_id, do: [agent_id], else: []
            end)

          %Event{
            type: "simulation.action_batch",
            phase: "actions",
            summary: "#{count} agents selected #{action_id}",
            targets: Enum.take(target_ids, 20),
            payload: %{
              "action_id" => action_id,
              "agent_count" => count,
              "sampled_targets" => min(count, 20)
            },
            source_ref: "action:#{action_id}",
            provenance: provenance(script)
          }
        end)

      blocked_events =
        if map_size(resolved.blocked) == 0 do
          []
        else
          [
            %Event{
              type: "simulation.action_batch",
              phase: "actions",
              summary: "Some agents used the conservative no-op fallback",
              payload: %{"blocked" => resolved.blocked},
              source_ref: "action:fallback:no_op",
              provenance: provenance(script)
            }
          ]
        end

      recent =
        resolved.emitted
        |> Enum.sort_by(&{&1["actor"], &1["type"]})
        |> Kernel.++(state["recent_events"])
        |> Enum.take(@recent_event_limit)

      round_events =
        (state["round_events"] || []) ++
          Enum.sort_by(resolved.emitted, &{&1["actor"], &1["type"]})

      next =
        next
        |> Map.put("action_counts", action_counts)
        |> Map.put("recent_events", recent)
        |> Map.put("round_events", round_events)

      {:ok, next, action_events ++ blocked_events, applied, resolved.changes + deferred_changes}
    else
      {:error, reason} ->
        {:error, {:resource_ledger_inconsistency, reason}}
    end
  end

  defp apply_agent_action(state, agent, action, round) do
    {local_effects, deferred_effects} =
      action["effects"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.split_with(fn {effect, _index} -> not deferred_effect?(effect) end)

    cost_operations =
      action["costs"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {cost, index} ->
        if number(cost["amount"]) == 0 do
          []
        else
          [
            transaction(
              "consume",
              cost["resource"],
              "agent:#{agent["id"]}",
              nil,
              cost["amount"],
              round,
              "actions",
              "action:#{action["id"]}:cost:#{index}",
              agent["id"],
              ["action:#{action["id"]}", "cost"]
            )
          ]
        end
      end)

    with {:ok, next, effect_operations, changes} <-
           apply_effects(
             %{
               "agents" => [agent],
               "world" => state["world"],
               "relationships" => state["relationships"]
             },
             Enum.map(local_effects, &elem(&1, 0)),
             [0],
             agent["id"],
             round,
             "actions",
             "action:#{action["id"]}"
           ) do
      {:ok, hd(next["agents"]), cost_operations ++ effect_operations, deferred_effects, changes}
    end
  end

  defp add_deferred(groups, action_id, actor_id, effects) do
    Enum.reduce(effects, groups, fn {effect, index}, current ->
      key = {action_id, index, ContentHash.digest(effect)}

      Map.update(
        current,
        key,
        %{action_id: action_id, index: index, effect: effect, actor_ids: [actor_id]},
        &Map.update!(&1, :actor_ids, fn actor_ids -> [actor_id | actor_ids] end)
      )
    end)
  end

  defp apply_deferred_effects(state, groups, round) do
    index_by_id =
      state["agents"]
      |> Enum.with_index()
      |> Map.new(fn {agent, index} -> {agent["id"], index} end)

    groups
    |> Map.values()
    |> Enum.sort_by(&{&1.action_id, &1.index})
    |> Enum.reduce_while({:ok, state, [], 0}, fn group, {:ok, current, operations, changes} ->
      indices =
        group.actor_ids
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&index_by_id[&1])
        |> Enum.reject(&is_nil/1)

      case apply_effects(
             current,
             [group.effect],
             indices,
             nil,
             round,
             "actions",
             "action:#{group.action_id}:deferred:#{group.index}"
           ) do
        {:ok, next, applied, effect_changes} ->
          {:cont, {:ok, next, operations ++ applied, changes + effect_changes}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp deferred_effect?(%{"op" => op})
       when op in ~w(set_relationship adjust_relationship),
       do: true

  defp deferred_effect?(%{"target" => %{"relationship_neighbors" => _target}}), do: true
  defp deferred_effect?(_effect), do: false

  defp apply_transitions(run_record_id, state, script, round) do
    script
    |> Map.get("transitions", [])
    |> ordered_transitions()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, [], [], 0}, fn {transition, transition_index},
                                                     {:ok, current, events, transactions, changes} ->
      matching_events =
        current["round_events"]
        |> List.wrap()
        |> Enum.filter(&transition_matches?(transition["when"] || %{}, &1))

      if matching_events == [] do
        {:cont, {:ok, current, events, transactions, changes}}
      else
        {indices, relationship_weights} =
          transition_target_indices(
            transition["target"] || %{},
            current,
            matching_events
          )

        case apply_effects(
               current,
               transition["effects"] || [],
               indices,
               nil,
               round,
               "transitions",
               "transition:#{transition["id"]}",
               relationship_weights
             ) do
          {:ok, next, operations, effect_changes} ->
            case apply_resource_operations(run_record_id, operations) do
              {:ok, applied} ->
                emitted = transition_emissions(transition, round, indices)
                recent_emitted = Enum.map(emitted, &Map.delete(&1, "source_indices"))

                next =
                  next
                  |> Map.update("round_events", emitted, &(&1 ++ emitted))
                  |> Map.update("recent_events", recent_emitted, fn recent ->
                    Enum.take(recent_emitted ++ recent, @recent_event_limit)
                  end)

                event = %Event{
                  type: "simulation.transition",
                  phase: "transitions",
                  summary: "Transition #{transition["id"]} applied",
                  targets: sampled_targets(next["agents"], indices),
                  payload: %{
                    "transition_id" => transition["id"],
                    "target_count" => length(indices),
                    "matching_event_count" => length(matching_events),
                    "emitted_event_count" => length(emitted)
                  },
                  source_ref: "transition:#{transition["id"]}",
                  provenance: provenance(script),
                  priority: transition_index
                }

                {:cont,
                 {:ok, next, events ++ [event], transactions ++ applied, changes + effect_changes}}

              {:error, reason} ->
                {:halt, {:error, {:resource_ledger_inconsistency, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp apply_effects(
         state,
         effects,
         indices,
         actor_id,
         round,
         phase,
         source_ref,
         relationship_weights \\ %{}
       ) do
    effects
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, [], 0}, fn {effect, index},
                                                 {:ok, current, operations, changes} ->
      {effect_indices, effect_weights} =
        effect_target(current, indices, actor_id, effect["target"], relationship_weights)

      case apply_effect(
             current,
             effect,
             effect_indices,
             actor_id,
             round,
             phase,
             source_ref,
             index,
             effect_weights
           ) do
        {:ok, next, operation, effect_changes} ->
          operations = if operation, do: operations ++ List.wrap(operation), else: operations
          {:cont, {:ok, next, operations, changes + effect_changes}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_effect(
         state,
         %{"op" => "set_world", "path" => path, "value" => value},
         _indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         _relationship_weights
       ) do
    previous = state["world"][path]
    {:ok, put_in(state, ["world", path], value), nil, if(previous == value, do: 0, else: 1)}
  end

  defp apply_effect(
         state,
         %{"op" => "adjust_world", "path" => path, "value" => expression},
         _indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         relationship_weights
       ) do
    previous = number(state["world"][path])

    amount =
      numeric(
        expression,
        facts(%{}, state["world"], first_relationship_weight(relationship_weights))
      )

    value = round_number(previous + amount)
    {:ok, put_in(state, ["world", path], value), nil, if(previous == value, do: 0, else: 1)}
  end

  defp apply_effect(
         state,
         %{"op" => "set_agent", "path" => "state." <> path, "value" => value},
         indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         _relationship_weights
       ) do
    agents = update_agents(state["agents"], indices, &put_in(&1, ["state", path], value))
    {:ok, Map.put(state, "agents", agents), nil, changed_count(state["agents"], agents, indices)}
  end

  defp apply_effect(
         state,
         %{"op" => "adjust_attribute", "path" => path, "value" => expression},
         indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         relationship_weights
       ) do
    attribute = String.replace_prefix(path, "attributes.", "")

    agents =
      update_agents_with_index(state["agents"], indices, fn agent, index ->
        previous = number(get_in(agent, ["attributes", attribute]))

        value =
          previous +
            numeric(expression, facts(agent, state["world"], relationship_weights[index]))

        put_in(agent, ["attributes", attribute], round_number(value))
      end)

    {:ok, Map.put(state, "agents", agents), nil, changed_count(state["agents"], agents, indices)}
  end

  defp apply_effect(
         state,
         %{"op" => "adjust_resource"} = effect,
         indices,
         actor_id,
         round,
         phase,
         source_ref,
         index,
         relationship_weights
       ) do
    operations =
      state["agents"]
      |> selected_agents_with_index(indices)
      |> Enum.flat_map(fn {agent, agent_index} ->
        amount =
          numeric(
            effect["amount"],
            facts(agent, state["world"], relationship_weights[agent_index])
          )

        if amount == 0 do
          []
        else
          [
            transaction(
              "adjust",
              effect["resource"],
              nil,
              "agent:#{agent["id"]}",
              amount,
              round,
              phase,
              "#{source_ref}:effect:#{index}",
              actor_id || agent["id"],
              [source_ref]
            )
          ]
        end
      end)

    {:ok, state, operations, length(operations)}
  end

  defp apply_effect(
         state,
         %{"op" => "transfer_resource"} = effect,
         indices,
         actor_id,
         round,
         phase,
         source_ref,
         index,
         relationship_weights
       ) do
    operations =
      state["agents"]
      |> selected_agents_with_index(indices)
      |> Enum.flat_map(fn {agent, agent_index} ->
        target_id = stable_target(agent["id"], state["relationships"])
        from = account(effect["from"], agent["id"], target_id)
        to = account(effect["to"], agent["id"], target_id)

        amount =
          numeric(
            effect["amount"],
            facts(agent, state["world"], relationship_weights[agent_index])
          )

        if (from && to && from != to) and amount != 0 do
          [
            transaction(
              "transfer",
              effect["resource"],
              from,
              to,
              amount,
              round,
              phase,
              "#{source_ref}:effect:#{index}",
              actor_id || agent["id"],
              [source_ref]
            )
          ]
        else
          []
        end
      end)

    {:ok, state, operations, length(operations)}
  end

  defp apply_effect(
         state,
         %{"op" => op, "relationship" => type, "value" => expression},
         indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         _relationship_weights
       )
       when op in ~w(set_relationship adjust_relationship) do
    target_ids =
      state["agents"]
      |> selected_agents(indices)
      |> MapSet.new(& &1["id"])

    agents_by_id = Map.new(state["agents"], &{&1["id"], &1})

    relationships =
      Enum.map(state["relationships"], fn relationship ->
        selected? =
          relationship["type"] == type and
            (MapSet.member?(target_ids, relationship["source"]) or
               MapSet.member?(target_ids, relationship["target"]))

        if selected? do
          previous = number(relationship["weight"])
          agent = agents_by_id[relationship["source"]] || %{}
          amount = numeric(expression, facts(agent, state["world"], previous))
          value = if op == "set_relationship", do: amount, else: previous + amount

          Map.put(
            relationship,
            "weight",
            value |> max(0.0) |> min(1.0) |> round_number()
          )
        else
          relationship
        end
      end)

    changes =
      state["relationships"]
      |> Enum.zip(relationships)
      |> Enum.count(fn {previous, next} -> previous != next end)

    {:ok, Map.put(state, "relationships", relationships), nil, changes}
  end

  defp apply_effect(
         _state,
         effect,
         _indices,
         _actor,
         _round,
         _phase,
         _source,
         _index,
         _relationship_weights
       ),
       do: {:error, {:unsupported_effect, effect["op"]}}

  defp apply_resource_operations(_run_record_id, []), do: {:ok, []}

  defp apply_resource_operations(run_record_id, operations),
    do: ResourceLedger.apply_batch(run_record_id, operations)

  defp transaction(
         operation,
         resource,
         source,
         destination,
         amount,
         round,
         phase,
         source_ref,
         actor_id,
         tags
       ) do
    idempotency_key =
      ContentHash.digest(%{
        "operation" => operation,
        "resource" => resource,
        "source" => source,
        "destination" => destination,
        "amount" => amount,
        "round" => round,
        "phase" => phase,
        "source_ref" => source_ref,
        "actor" => actor_id
      })

    %{
      operation: operation,
      resource_id: resource,
      source_account: source,
      destination_account: destination,
      amount: amount,
      round: round,
      phase: phase,
      source_ref: source_ref,
      tags: tags,
      idempotency_key: idempotency_key,
      order_key: "#{phase}:#{source_ref}:#{actor_id}:#{resource}:#{operation}"
    }
  end

  defp choose_action_with_decision(
         %{"action_id" => action_id},
         policy_id,
         policies,
         _facts,
         _seed,
         _round,
         _agent_id
       ) do
    case policies[policy_id] do
      %{"kind" => "hybrid", "candidates" => candidates} when is_list(candidates) ->
        if action_id in candidates, do: {:ok, action_id}, else: {:error, :invalid_model_action}

      _policy ->
        {:error, :invalid_model_policy}
    end
  end

  defp choose_action_with_decision(
         _decision,
         policy_id,
         policies,
         facts,
         seed,
         round,
         agent_id
       ),
       do: choose_action(policy_id, policies, facts, seed, round, agent_id)

  defp choose_action(nil, _policies, _facts, _seed, _round, _agent_id),
    do: {:error, :missing_policy}

  defp choose_action(policy_id, policies, facts, seed, round, agent_id) do
    case policies[policy_id] do
      %{"kind" => "fixed", "action" => action} ->
        {:ok, action}

      %{"kind" => "weighted", "candidates" => candidates} ->
        weighted_choice(candidates, facts, seed, round, agent_id, policy_id)

      %{"kind" => "rule_set"} = policy ->
        action =
          Enum.find_value(policy["rules"] || [], fn rule ->
            if condition_true?(rule["when"], facts), do: rule["action"]
          end)

        {:ok, action || policy["fallback"]}

      %{"kind" => "hybrid", "fallback" => fallback} ->
        choose_action(fallback, policies, facts, seed, round, agent_id)

      _policy ->
        {:error, :invalid_policy}
    end
  end

  defp weighted_choice(candidates, facts, seed, round, agent_id, policy_id) do
    weighted =
      candidates
      |> Enum.map(fn {action, expression} -> {action, max(numeric(expression, facts), 0.0)} end)
      |> Enum.sort_by(&elem(&1, 0))

    total = Enum.sum_by(weighted, &elem(&1, 1))

    if total <= 0 do
      {:error, :empty_policy}
    else
      position = unit(seed, "#{round}:#{agent_id}:#{policy_id}:weighted") * total

      weighted
      |> Enum.reduce_while(0.0, fn {action, weight}, cumulative ->
        next = cumulative + weight
        if position < next, do: {:halt, {:ok, action}}, else: {:cont, next}
      end)
      |> case do
        {:ok, action} -> {:ok, action}
        _cumulative -> {:ok, weighted |> List.last() |> elem(0)}
      end
    end
  end

  defp apply_memory_updates(agent, %{"memory_updates" => updates})
       when is_map(updates) and map_size(updates) > 0 do
    Map.update(agent, "state", updates, fn state -> Map.merge(state || %{}, updates) end)
  end

  defp apply_memory_updates(agent, _decision), do: agent

  defp can_pay?(agent, costs) do
    Enum.all?(costs, fn cost ->
      number(get_in(agent, ["resources", cost["resource"]])) >= number(cost["amount"])
    end)
  end

  defp observe(run_record_id, script, state) do
    script
    |> get_in(["observations", "metrics"])
    |> List.wrap()
    |> Map.new(fn metric -> {metric["id"], metric_value(run_record_id, metric, state)} end)
  end

  defp metric_value(_run_record_id, %{"kind" => "agent_fraction", "filter" => filter}, state) do
    count = Enum.count(state["agents"], &matches_filter?(&1, filter))
    if state["agents"] == [], do: 0.0, else: round_number(count / length(state["agents"]))
  end

  defp metric_value(_run_record_id, %{"kind" => "mean", "fact" => fact}, state) do
    values =
      state["agents"]
      |> Enum.map(&fact_value(fact, facts(&1, state["world"])))
      |> Enum.filter(&is_number/1)

    if values == [], do: 0.0, else: round_number(Enum.sum(values) / length(values))
  end

  defp metric_value(_run_record_id, %{"kind" => "action_count", "action" => action}, state),
    do: state["action_counts"][action] || 0

  defp metric_value(run_record_id, %{"kind" => "resource_sum", "resource" => resource}, _state),
    do: ResourceLedger.resource_sum(run_record_id, resource)

  defp metric_value(_run_record_id, %{"kind" => "world_value", "key" => key}, state),
    do: state["world"][key]

  defp metric_value(
         _run_record_id,
         %{"kind" => "relationship_count", "relationship" => type},
         state
       ),
       do: Enum.count(state["relationships"], &(&1["type"] == type))

  defp metric_value(_run_record_id, _metric, _state), do: nil

  defp stopping_reason(script, round, observations, unchanged_rounds) do
    Enum.find_value(script["stopping_conditions"] || [], fn
      %{"kind" => "final_round"} ->
        if round >= get_in(script, ["clock", "count"]), do: "final_round"

      %{"kind" => "no_state_changes", "rounds" => threshold} ->
        if unchanged_rounds >= threshold, do: "no_state_changes"

      %{"kind" => "metric_threshold", "metric" => metric, "op" => op, "value" => value} ->
        if compare_metric(observations[metric], op, value), do: "metric_threshold:#{metric}"

      _condition ->
        nil
    end)
  end

  defp compare_metric(current, op, expected) when is_number(current) and is_number(expected) do
    case op do
      "gt" -> current > expected
      "gte" -> current >= expected
      "lt" -> current < expected
      "lte" -> current <= expected
      "eq" -> current == expected
      _op -> false
    end
  end

  defp compare_metric(_current, _op, _expected), do: false

  defp condition_true?(nil, _facts), do: true

  defp condition_true?(%{"all" => children}, facts),
    do: Enum.all?(children, &condition_true?(&1, facts))

  defp condition_true?(%{"any" => children}, facts),
    do: Enum.any?(children, &condition_true?(&1, facts))

  defp condition_true?(%{"not" => child}, facts), do: not condition_true?(child, facts)

  defp condition_true?(%{"fact" => fact, "op" => op} = condition, facts) do
    current = fact_value(fact, facts)
    expected = condition["value"]

    case op do
      "eq" -> current == expected
      "neq" -> current != expected
      "gt" -> comparable?(current, expected) and current > expected
      "gte" -> comparable?(current, expected) and current >= expected
      "lt" -> comparable?(current, expected) and current < expected
      "lte" -> comparable?(current, expected) and current <= expected
      "in" -> is_list(expected) and current in expected
      "not_in" -> is_list(expected) and current not in expected
      "exists" -> not is_nil(current)
      _op -> false
    end
  end

  defp condition_true?(_condition, _facts), do: false

  defp numeric(value, _facts) when is_number(value), do: value / 1
  defp numeric(value, _facts) when is_binary(value), do: number(value)
  defp numeric(%{"fact" => fact}, facts), do: fact_value(fact, facts) |> number()
  defp numeric(%{"add" => [left, right]}, facts), do: numeric(left, facts) + numeric(right, facts)

  defp numeric(%{"subtract" => [left, right]}, facts),
    do: numeric(left, facts) - numeric(right, facts)

  defp numeric(%{"multiply" => [left, right]}, facts),
    do: numeric(left, facts) * numeric(right, facts)

  defp numeric(%{"divide" => [left, right]}, facts) do
    denominator = numeric(right, facts)
    if denominator == 0, do: 0.0, else: numeric(left, facts) / denominator
  end

  defp numeric(%{"min" => [left, right]}, facts),
    do: min(numeric(left, facts), numeric(right, facts))

  defp numeric(%{"max" => [left, right]}, facts),
    do: max(numeric(left, facts), numeric(right, facts))

  defp numeric(%{"clamp" => [value, minimum, maximum]}, facts),
    do: numeric(value, facts) |> max(numeric(minimum, facts)) |> min(numeric(maximum, facts))

  defp numeric(_value, _facts), do: 0.0

  defp facts(agent, world, relationship_weight \\ nil) do
    %{
      agent: agent,
      world: world,
      decision: %{"uncertainty" => 0.0},
      event: %{"relationship_weight" => relationship_weight}
    }
  end

  defp fact_value("world." <> key, facts), do: get_in(facts, [:world, key])

  defp fact_value("agent.attributes." <> key, facts),
    do: get_in(facts, [:agent, "attributes", key])

  defp fact_value("agent.state." <> key, facts), do: get_in(facts, [:agent, "state", key])

  defp fact_value("agent.resources." <> key, facts),
    do: get_in(facts, [:agent, "resources", key]) |> number()

  defp fact_value("decision.uncertainty", facts), do: get_in(facts, [:decision, "uncertainty"])

  defp fact_value("event.relationship_weight", facts),
    do: get_in(facts, [:event, "relationship_weight"])

  defp fact_value(_fact, _facts), do: nil

  defp audience_indices(agents, %{"all" => true}), do: indices(agents)

  defp audience_indices(agents, %{"agent_type" => type}) do
    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} -> if agent["type"] == type, do: [index], else: [] end)
  end

  defp audience_indices(_agents, _audience), do: []

  defp round_event(event, round) do
    %{
      "type" => event["id"],
      "round" => round,
      "payload" => event["payload"] || %{},
      "audience" => event["audience"] || %{}
    }
  end

  defp transition_emissions(transition, round, source_indices) do
    Enum.map(transition["emits"] || [], fn emission ->
      %{
        "type" => emission["type"],
        "payload" => emission["payload"] || %{},
        "round" => round,
        "transition" => transition["id"],
        "source_indices" => source_indices
      }
    end)
  end

  defp ordered_transitions(transitions) do
    by_id = Map.new(transitions, &{&1["id"], &1})

    producers =
      Enum.reduce(transitions, %{}, fn transition, current ->
        Enum.reduce(transition["emits"] || [], current, fn emission, acc ->
          Map.update(acc, emission["type"], [transition["id"]], &[transition["id"] | &1])
        end)
      end)

    Enum.sort_by(transitions, fn transition ->
      {
        transition_depth(transition["id"], by_id, producers, MapSet.new()),
        transition["id"]
      }
    end)
  end

  defp transition_depth(id, by_id, producers, visiting) do
    if MapSet.member?(visiting, id) do
      0
    else
      transition = by_id[id] || %{}
      event_type = get_in(transition, ["when", "event_type"])
      producer_ids = Enum.reject(producers[event_type] || [], &(&1 == id))

      case producer_ids do
        [] ->
          0

        ids ->
          visiting = MapSet.put(visiting, id)

          1 + Enum.max(Enum.map(ids, &transition_depth(&1, by_id, producers, visiting)))
      end
    end
  end

  defp transition_matches?(when_clause, event) do
    payload = event["payload"] || %{}
    expected_payload = when_clause["payload"] || %{}

    event["type"] == when_clause["event_type"] and
      Enum.all?(expected_payload, fn {key, value} -> payload[key] == value end)
  end

  defp transition_target_indices(%{"audience" => true}, state, matching_events) do
    if matching_events == [], do: {[], %{}}, else: {indices(state["agents"]), %{}}
  end

  defp transition_target_indices(%{"self" => true}, state, matching_events) do
    selected = event_source_indices(state, matching_events)
    {selected, %{}}
  end

  defp transition_target_indices(
         %{"relationship_neighbors" => target},
         state,
         matching_events
       ) do
    state
    |> event_source_indices(matching_events)
    |> then(&neighbor_indices(state, &1, target["type"], target["limit"] || 20))
  end

  defp transition_target_indices(_target, _state, _matching_events), do: {[], %{}}

  defp effect_target(state, indices, actor_id, target, inherited_weights)
       when is_nil(target) or target == "audience" do
    selected =
      if target == "audience", do: indices, else: actor_or_indices(state, actor_id, indices)

    {selected, select_weights(inherited_weights, selected)}
  end

  defp effect_target(_state, indices, _actor_id, %{"audience" => true}, inherited_weights),
    do: {indices, select_weights(inherited_weights, indices)}

  defp effect_target(state, indices, actor_id, %{"self" => true}, inherited_weights) do
    selected = actor_or_indices(state, actor_id, indices)
    {selected, select_weights(inherited_weights, selected)}
  end

  defp effect_target(
         state,
         indices,
         actor_id,
         %{"relationship_neighbors" => target},
         _inherited_weights
       ) do
    sources = actor_or_indices(state, actor_id, indices)
    neighbor_indices(state, sources, target["type"], target["limit"] || 20)
  end

  defp effect_target(_state, indices, _actor_id, _target, inherited_weights),
    do: {indices, select_weights(inherited_weights, indices)}

  defp actor_or_indices(_state, nil, indices), do: indices

  defp actor_or_indices(state, actor_id, indices) do
    case Enum.find_index(state["agents"], &(&1["id"] == actor_id)) do
      nil -> indices
      index -> [index]
    end
  end

  defp event_source_indices(state, events) do
    index_by_id =
      state["agents"]
      |> Enum.with_index()
      |> Map.new(fn {agent, index} -> {agent["id"], index} end)

    events
    |> Enum.flat_map(fn event ->
      cond do
        is_list(event["source_indices"]) ->
          event["source_indices"]

        is_integer(index_by_id[event["actor"]]) ->
          [index_by_id[event["actor"]]]

        true ->
          audience_indices(state["agents"], event["audience"] || %{})
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp neighbor_indices(state, source_indices, type, limit) do
    source_ids =
      state["agents"]
      |> selected_agents(source_indices)
      |> MapSet.new(& &1["id"])

    {_counts, selected} =
      state["relationships"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce({%{}, %{}}, fn relationship, {counts, selected} ->
        if relationship["type"] == type do
          {counts, selected} =
            select_neighbor(
              counts,
              selected,
              source_ids,
              relationship["source"],
              relationship["target"],
              relationship["weight"],
              limit
            )

          if relationship["directed"] == true do
            {counts, selected}
          else
            select_neighbor(
              counts,
              selected,
              source_ids,
              relationship["target"],
              relationship["source"],
              relationship["weight"],
              limit
            )
          end
        else
          {counts, selected}
        end
      end)

    index_by_id =
      state["agents"]
      |> Enum.with_index()
      |> Map.new(fn {agent, index} -> {agent["id"], index} end)

    selected
    |> Enum.flat_map(fn {agent_id, weight} ->
      case index_by_id[agent_id] do
        nil -> []
        index -> [{index, number(weight)}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> then(fn rows ->
      {Enum.map(rows, &elem(&1, 0)), Map.new(rows)}
    end)
  end

  defp select_neighbor(counts, selected, source_ids, source, target, weight, limit) do
    count = counts[source] || 0

    if MapSet.member?(source_ids, source) and count < limit do
      {
        Map.put(counts, source, count + 1),
        Map.put_new(selected, target, weight)
      }
    else
      {counts, selected}
    end
  end

  defp select_weights(weights, indices), do: Map.take(weights, indices)

  defp first_relationship_weight(weights) do
    weights
    |> Enum.sort_by(&elem(&1, 0))
    |> List.first()
    |> case do
      {_index, weight} -> weight
      nil -> nil
    end
  end

  defp indices([]), do: []
  defp indices(agents), do: Enum.to_list(0..(length(agents) - 1))

  defp update_agents(agents, indices, update),
    do: update_agents_with_index(agents, indices, fn agent, _index -> update.(agent) end)

  defp update_agents_with_index(agents, indices, update) do
    selected = MapSet.new(indices)

    agents
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      if MapSet.member?(selected, index), do: update.(agent, index), else: agent
    end)
  end

  defp changed_count(previous_agents, next_agents, indices) do
    selected = MapSet.new(indices)

    previous_agents
    |> Enum.zip(next_agents)
    |> Enum.with_index()
    |> Enum.count(fn {{previous, next}, index} ->
      MapSet.member?(selected, index) and previous != next
    end)
  end

  defp selected_agents(agents, indices) do
    selected = MapSet.new(indices)

    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} ->
      if MapSet.member?(selected, index), do: [agent], else: []
    end)
  end

  defp selected_agents_with_index(agents, indices) do
    selected = MapSet.new(indices)

    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} ->
      if MapSet.member?(selected, index), do: [{agent, index}], else: []
    end)
  end

  defp matches_filter?(agent, filter) do
    Enum.all?(filter, fn
      {"state." <> path, expected} -> get_in(agent, ["state", path]) == expected
      _filter -> false
    end)
  end

  defp sampled_targets(agents, indices),
    do: indices |> Enum.take(20) |> Enum.map(&Enum.at(agents, &1)["id"])

  defp stable_target(agent_id, relationships) do
    relationships
    |> Enum.flat_map(fn relationship ->
      cond do
        relationship["source"] == agent_id ->
          [relationship["target"]]

        relationship["directed"] != true and relationship["target"] == agent_id ->
          [relationship["source"]]

        true ->
          []
      end
    end)
    |> Enum.sort()
    |> List.first()
  end

  defp account("agent", agent_id, _target_id), do: "agent:#{agent_id}"
  defp account("world", _agent_id, _target_id), do: "world"
  defp account("target", _agent_id, nil), do: nil
  defp account("target", _agent_id, target_id), do: "agent:#{target_id}"
  defp account(_kind, _agent_id, _target_id), do: nil

  defp blocked_reason(false), do: "precondition_or_resource"
  defp blocked_reason(nil), do: "missing_action"
  defp blocked_reason({:error, reason}), do: to_string(reason)
  defp blocked_reason(_reason), do: "fallback"

  defp provenance(script) do
    %{
      "script_id" => get_in(script, ["metadata", "id"]),
      "script_schema" => script["hydra_simulation_script"]
    }
  end

  defp comparable?(left, right), do: is_number(left) and is_number(right)
  defp number(value) when is_number(value), do: value / 1

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _error -> 0.0
    end
  end

  defp number(_value), do: 0.0
  defp round_number(value) when is_integer(value), do: value
  defp round_number(value) when is_float(value), do: Float.round(value, 6)
  defp round_number(value), do: value

  defp unit(seed, path) do
    <<value::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, "#{seed}:#{path}")

    value / 18_446_744_073_709_551_616
  end
end
