defmodule HydraAgent.Simulations.ScriptPreviewEngine do
  @moduledoc "Executes a deterministic, side-effect-free two-round Script preview."

  alias HydraAgent.Simulations.{ContentHash, PopulationModel, ScriptValidator, SimulationScript}

  @maximum_agents 12
  @maximum_rounds 2

  def run(script, population_model, opts \\ [])

  def run(%SimulationScript{} = record, %PopulationModel{} = population_model, opts),
    do: run(record.script, population_model, opts)

  def run(script, %PopulationModel{} = population_model, opts) when is_map(script) do
    population = PopulationModel.contract(population_model)
    rounds = min(get_in(script, ["clock", "count"]) || @maximum_rounds, @maximum_rounds)
    seed = Keyword.get(opts, :seed, population_model.seed)
    model_budget? = Keyword.get(opts, :model_budget?, false)

    with {:ok, _report} <-
           ScriptValidator.validate(script, population, model_budget?: model_budget?),
         agents when agents != [] <- preview_agents(population_model),
         relationships <- preview_relationships(population_model, agents),
         {:ok, result} <- execute(script, agents, relationships, rounds, seed) do
      summary = %{
        "rounds_completed" => rounds,
        "agent_count" => length(agents),
        "model_calls" => 0,
        "action_counts" => result.action_counts,
        "event_count" => length(result.events),
        "state_change_count" => result.state_changes,
        "observations" => result.observations,
        "world_state" => result.world,
        "world_resources" => result.world_resources,
        "final_agent_state_hash" => ContentHash.digest(result.agents),
        "final_relationship_state_hash" => ContentHash.digest(result.relationships)
      }

      {:ok,
       %{
         status: "passed",
         rounds_requested: rounds,
         rounds_completed: rounds,
         agent_count: length(agents),
         seed: seed,
         summary: summary,
         errors: [],
         result_hash: ContentHash.digest(summary)
       }}
    else
      [] ->
        failed(rounds, 0, seed, [
          preview_error("no_preview_agents", "no representative agents are available")
        ])

      {:error, errors} when is_list(errors) ->
        failed(rounds, 0, seed, sanitize_errors(errors))

      {:error, error} when is_map(error) ->
        failed(rounds, 0, seed, [error])

      _ ->
        failed(rounds, 0, seed, [
          preview_error("preview_failed", "the miniature run could not complete")
        ])
    end
  end

  def run(_script, _population_model, _opts),
    do: failed(2, 0, 0, [preview_error("invalid_script", "the script is not an object")])

  defp execute(script, agents, relationships, rounds, seed) do
    initial = %{
      agents: agents,
      relationships: relationships,
      world: get_in(script, ["world", "state"]) || %{},
      world_resources: get_in(script, ["world", "resources"]) || %{},
      events: [],
      action_counts: %{},
      state_changes: 0,
      observations: []
    }

    Enum.reduce_while(1..rounds, {:ok, initial}, fn round, {:ok, state} ->
      with {:ok, state} <- apply_scheduled_events(script, state, round, "before_actions"),
           {:ok, state} <- run_actions(script, state, round, seed),
           {:ok, state} <- apply_scheduled_events(script, state, round, "after_actions"),
           {:ok, state} <- apply_transitions(script, state, round),
           {:ok, observations} <- observe(script, state) do
        world = Map.put(state.world, "current_round", round)

        next = %{
          state
          | world: world,
            observations: state.observations ++ [%{"round" => round, "metrics" => observations}]
        }

        {:cont, {:ok, next}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp preview_agents(population_model) do
    population_model.compile_summary
    |> Map.get("representatives", [])
    |> Enum.take(@maximum_agents)
    |> Enum.map(fn representative ->
      %{
        "id" => representative["agent_id"],
        "type" => representative["agent_type"],
        "attributes" => representative["attributes"] || %{},
        "resources" => representative["resources"] || %{},
        "state" => representative["state"] || %{}
      }
    end)
  end

  defp preview_relationships(population_model, agents) do
    agent_ids = MapSet.new(agents, & &1["id"])

    population_model.compile_summary
    |> Map.get("representatives", [])
    |> Enum.flat_map(&(&1["important_relationships"] || []))
    |> Enum.filter(fn relationship ->
      MapSet.member?(agent_ids, relationship["source"]) and
        MapSet.member?(agent_ids, relationship["target"])
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  defp apply_scheduled_events(script, state, round, phase) do
    script
    |> Map.get("events", [])
    |> Enum.filter(&(&1["at_round"] == round and &1["phase"] == phase))
    |> Enum.reduce_while({:ok, state}, fn event, {:ok, current} ->
      case apply_event(event, current, round) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_event(event, state, round) do
    audience = audience_indices(state.agents, event["audience"] || %{})

    with {:ok, next} <- apply_effects(event["effects"] || [], state, audience) do
      {:ok,
       %{
         next
         | events:
             next.events ++
               [
                 %{
                   "type" => event["id"],
                   "payload" => event["payload"] || %{},
                   "audience" => event["audience"] || %{},
                   "round" => round
                 }
               ]
       }}
    end
  end

  defp run_actions(script, state, round, seed) do
    assignments = Map.new(script["agent_types"] || [], &{&1["id"], &1["policy"]})
    policies = Map.new(script["policies"] || [], &{&1["id"], &1})
    actions = Map.new(script["actions"] || [], &{&1["id"], &1})

    state.agents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {agent, index}, {:ok, current} ->
      facts = facts(agent, current.world)

      with {:ok, action_id} <- choose_action(assignments[agent["type"]], policies, facts),
           action when not is_nil(action) <- actions[action_id],
           true <- action_id in eligible_actions(action, agent),
           true <- condition_true?(action["preconditions"], facts),
           {:ok, paid_agent} <- pay_costs(agent, action["costs"] || []),
           agents = List.replace_at(current.agents, index, paid_agent),
           {:ok, effected} <-
             apply_effects(action["effects"] || [], %{current | agents: agents}, [index]) do
        events =
          Enum.map(action["emits"] || [], fn emission ->
            %{
              "type" => emission["type"],
              "payload" => emission["payload"] || %{},
              "agent_index" => index,
              "actor" => agent["id"],
              "round" => round,
              "seed" => seed
            }
          end)

        next = %{
          effected
          | events: effected.events ++ events,
            action_counts: Map.update(effected.action_counts, action_id, 1, &(&1 + 1))
        }

        {:cont, {:ok, next}}
      else
        false ->
          {:halt,
           {:error,
            preview_error(
              "no_reachable_action",
              "a representative agent has no reachable action in the preview"
            )}}

        nil ->
          {:halt,
           {:error, preview_error("missing_action", "a policy selected an undeclared action")}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp eligible_actions(action, agent) do
    if agent["type"] in (action["actors"] || []), do: [action["id"]], else: []
  end

  defp choose_action(nil, _policies, _facts),
    do: {:error, preview_error("missing_policy", "an agent type has no assigned policy")}

  defp choose_action(policy_id, policies, facts) do
    case policies[policy_id] do
      %{"kind" => "fixed", "action" => action} ->
        {:ok, action}

      %{"kind" => "weighted", "candidates" => candidates} ->
        candidates
        |> Enum.map(fn {action, expression} -> {action, numeric(expression, facts)} end)
        |> Enum.sort_by(fn {action, score} -> {-score, action} end)
        |> List.first()
        |> case do
          {action, _score} -> {:ok, action}
          nil -> {:error, preview_error("empty_policy", "a weighted policy has no candidates")}
        end

      %{"kind" => "rule_set"} = policy ->
        action =
          policy
          |> Map.get("rules", [])
          |> Enum.find_value(fn rule ->
            if condition_true?(rule["when"], facts), do: rule["action"], else: nil
          end)

        {:ok, action || policy["fallback"]}

      %{"kind" => "hybrid", "fallback" => fallback} ->
        choose_action(fallback, policies, facts)

      _ ->
        {:error, preview_error("invalid_policy", "the assigned policy cannot be evaluated")}
    end
  end

  defp pay_costs(agent, costs) do
    Enum.reduce_while(costs, {:ok, agent}, fn cost, {:ok, current} ->
      resource = cost["resource"]
      amount = cost["amount"]
      balance = get_in(current, ["resources", resource]) || 0

      if is_number(balance) and is_number(amount) and balance >= amount do
        {:cont, {:ok, put_in(current, ["resources", resource], round_number(balance - amount))}}
      else
        {:halt,
         {:error,
          preview_error(
            "insufficient_resource",
            "a representative agent cannot satisfy a declared action cost"
          )}}
      end
    end)
  end

  defp apply_effects(effects, state, audience_indices, relationship_weights \\ %{}) do
    Enum.reduce_while(effects, {:ok, state}, fn effect, {:ok, current} ->
      {indices, weights} =
        effect_target(current, audience_indices, effect["target"], relationship_weights)

      case apply_effect(effect, current, indices, weights) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_effect(
         %{"op" => "set_world", "path" => path, "value" => value},
         state,
         _indices,
         _relationship_weights
       ) do
    previous = state.world[path]
    changes = if previous == value, do: 0, else: 1

    {:ok,
     %{
       state
       | world: Map.put(state.world, path, value),
         state_changes: state.state_changes + changes
     }}
  end

  defp apply_effect(
         %{"op" => "adjust_world", "path" => path, "value" => expression},
         state,
         _indices,
         relationship_weights
       ) do
    previous = state.world[path] || 0
    amount = numeric(expression, facts(%{}, state.world, first_weight(relationship_weights)))
    value = round_number(previous + amount)
    changes = if previous == value, do: 0, else: 1

    {:ok,
     %{
       state
       | world: Map.put(state.world, path, value),
         state_changes: state.state_changes + changes
     }}
  end

  defp apply_effect(
         %{"op" => "set_agent", "path" => "state." <> path, "value" => value},
         state,
         indices,
         _relationship_weights
       ) do
    agents =
      update_agents(state.agents, indices, fn agent -> put_in(agent, ["state", path], value) end)

    changes = changed_count(state.agents, agents, indices)
    {:ok, %{state | agents: agents, state_changes: state.state_changes + changes}}
  end

  defp apply_effect(
         %{"op" => "adjust_attribute", "path" => path, "value" => expression},
         state,
         indices,
         relationship_weights
       ) do
    attribute = String.replace_prefix(path, "attributes.", "")

    agents =
      update_agents_with_index(state.agents, indices, fn agent, index ->
        facts = facts(agent, state.world, relationship_weights[index])
        previous = get_in(agent, ["attributes", attribute]) || 0

        put_in(
          agent,
          ["attributes", attribute],
          round_number(previous + numeric(expression, facts))
        )
      end)

    changes = changed_count(state.agents, agents, indices)
    {:ok, %{state | agents: agents, state_changes: state.state_changes + changes}}
  end

  defp apply_effect(
         %{"op" => "adjust_resource", "resource" => resource, "amount" => expression},
         state,
         indices,
         relationship_weights
       ) do
    agents =
      update_agents_with_index(state.agents, indices, fn agent, index ->
        facts = facts(agent, state.world, relationship_weights[index])
        previous = get_in(agent, ["resources", resource]) || 0

        put_in(
          agent,
          ["resources", resource],
          round_number(previous + numeric(expression, facts))
        )
      end)

    changes = changed_count(state.agents, agents, indices)
    {:ok, %{state | agents: agents, state_changes: state.state_changes + changes}}
  end

  defp apply_effect(
         %{"op" => op, "relationship" => type, "value" => expression},
         state,
         indices,
         _relationship_weights
       )
       when op in ~w(set_relationship adjust_relationship) do
    target_ids =
      state.agents
      |> selected_agents(indices)
      |> MapSet.new(& &1["id"])

    agents_by_id = Map.new(state.agents, &{&1["id"], &1})

    relationships =
      Enum.map(state.relationships, fn relationship ->
        selected? =
          relationship["type"] == type and
            (MapSet.member?(target_ids, relationship["source"]) or
               MapSet.member?(target_ids, relationship["target"]))

        if selected? do
          previous = number(relationship["weight"])
          agent = agents_by_id[relationship["source"]] || %{}
          amount = numeric(expression, facts(agent, state.world, previous))
          value = if op == "set_relationship", do: amount, else: previous + amount

          Map.put(relationship, "weight", value |> max(0.0) |> min(1.0) |> round_number())
        else
          relationship
        end
      end)

    changes = Enum.count(Enum.zip(state.relationships, relationships), fn {a, b} -> a != b end)

    {:ok,
     %{
       state
       | relationships: relationships,
         state_changes: state.state_changes + changes
     }}
  end

  defp apply_effect(%{"op" => "transfer_resource"} = effect, state, indices, weights) do
    Enum.reduce_while(indices, {:ok, state}, fn index, {:ok, current} ->
      agent = Enum.at(current.agents, index)
      target_id = stable_target(agent["id"], current.relationships)
      target_index = Enum.find_index(current.agents, &(&1["id"] == target_id))
      from = preview_account(effect["from"], index, target_index)
      to = preview_account(effect["to"], index, target_index)
      amount = numeric(effect["amount"], facts(agent, current.world, weights[index])) |> abs()

      case if(amount == 0,
             do: {:ok, current},
             else: transfer_preview(current, effect["resource"], from, to, amount)
           ) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_effect(_effect, _state, _indices, _relationship_weights),
    do:
      {:error,
       preview_error("unsupported_preview_effect", "the preview cannot apply one declared effect")}

  defp apply_transitions(script, state, round) do
    script
    |> Map.get("transitions", [])
    |> ordered_transitions()
    |> Enum.reduce_while({:ok, state}, fn transition, {:ok, current} ->
      matching_events =
        current.events
        |> Enum.filter(&(&1["round"] == round))
        |> Enum.filter(&transition_matches?(transition["when"] || %{}, &1))

      {indices, relationship_weights} =
        transition_target_indices(transition["target"] || %{}, current, matching_events)

      effect_result =
        if matching_events == [] do
          {:ok, current}
        else
          apply_effects(
            transition["effects"] || [],
            current,
            indices,
            relationship_weights
          )
        end

      with {:ok, effected} <- effect_result do
        emissions =
          Enum.map(transition["emits"] || [], fn emission ->
            %{
              "type" => emission["type"],
              "payload" => emission["payload"] || %{},
              "round" => round,
              "source_indices" => indices
            }
          end)

        emissions = if matching_events == [], do: [], else: emissions
        {:cont, {:ok, %{effected | events: effected.events ++ emissions}}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp transition_matches?(when_clause, event) do
    payload = event["payload"] || %{}
    expected_payload = when_clause["payload"] || %{}

    event["type"] == when_clause["event_type"] and
      Enum.all?(expected_payload, fn {key, value} -> payload[key] == value end)
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

  defp transition_target_indices(%{"self" => true}, state, events) do
    {event_source_indices(state, events), %{}}
  end

  defp transition_target_indices(%{"audience" => true}, state, events) do
    if events == [], do: {[], %{}}, else: {all_indices(state.agents), %{}}
  end

  defp transition_target_indices(%{"relationship_neighbors" => target}, state, events) do
    state
    |> event_source_indices(events)
    |> then(&neighbor_indices(state, &1, target["type"], target["limit"] || 20))
  end

  defp transition_target_indices(_target, _state, _events), do: {[], %{}}

  defp observe(script, state) do
    metrics = get_in(script, ["observations", "metrics"]) || []

    observations =
      Map.new(metrics, fn metric ->
        {metric["id"], metric_value(metric, state)}
      end)

    {:ok, observations}
  end

  defp metric_value(%{"kind" => "agent_fraction", "filter" => filter}, state) do
    count = Enum.count(state.agents, &matches_filter?(&1, filter))
    if state.agents == [], do: 0.0, else: round_number(count / length(state.agents))
  end

  defp metric_value(%{"kind" => "mean", "fact" => fact}, state) do
    values =
      state.agents
      |> Enum.map(&fact_value(fact, %{agent: &1, world: state.world, decision: %{}}))
      |> Enum.filter(&is_number/1)

    if values == [], do: 0.0, else: round_number(Enum.sum(values) / length(values))
  end

  defp metric_value(%{"kind" => "action_count", "action" => action}, state),
    do: state.action_counts[action] || 0

  defp metric_value(%{"kind" => "resource_sum", "resource" => resource}, state) do
    state.agents
    |> Enum.sum_by(&(get_in(&1, ["resources", resource]) || 0))
    |> round_number()
  end

  defp metric_value(%{"kind" => "world_value", "key" => key}, state), do: state.world[key]

  defp metric_value(%{"kind" => "relationship_count", "relationship" => type}, state),
    do: Enum.count(state.relationships, &(&1["type"] == type))

  defp metric_value(_metric, _state), do: nil

  defp matches_filter?(agent, filter) do
    Enum.all?(filter, fn {"state." <> path, expected} ->
      get_in(agent, ["state", path]) == expected
    end)
  end

  defp condition_true?(nil, _facts), do: true

  defp condition_true?(%{"all" => children}, facts),
    do: Enum.all?(children, &condition_true?(&1, facts))

  defp condition_true?(%{"any" => children}, facts),
    do: Enum.any?(children, &condition_true?(&1, facts))

  defp condition_true?(%{"not" => condition}, facts), do: not condition_true?(condition, facts)

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
      _ -> false
    end
  end

  defp condition_true?(_condition, _facts), do: false

  defp numeric(value, _facts) when is_number(value), do: value / 1
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

  defp numeric(%{"clamp" => [value, minimum, maximum]}, facts) do
    numeric(value, facts) |> max(numeric(minimum, facts)) |> min(numeric(maximum, facts))
  end

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
  defp fact_value("agent.resources." <> key, facts), do: get_in(facts, [:agent, "resources", key])
  defp fact_value("decision.uncertainty", facts), do: get_in(facts, [:decision, "uncertainty"])

  defp fact_value("event.relationship_weight", facts),
    do: get_in(facts, [:event, "relationship_weight"])

  defp fact_value(_fact, _facts), do: nil

  defp audience_indices(agents, %{"all" => true}), do: all_indices(agents)

  defp audience_indices(agents, %{"agent_type" => type}) do
    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} -> if agent["type"] == type, do: [index], else: [] end)
  end

  defp audience_indices(_agents, _audience), do: []

  defp effect_target(_state, indices, target, inherited_weights)
       when is_nil(target) or target == "self" or target == "audience",
       do: {indices, Map.take(inherited_weights, indices)}

  defp effect_target(_state, indices, %{"self" => true}, inherited_weights),
    do: {indices, Map.take(inherited_weights, indices)}

  defp effect_target(_state, indices, %{"audience" => true}, inherited_weights),
    do: {indices, Map.take(inherited_weights, indices)}

  defp effect_target(state, indices, %{"relationship_neighbors" => target}, _weights),
    do: neighbor_indices(state, indices, target["type"], target["limit"] || 20)

  defp effect_target(_state, indices, _target, inherited_weights),
    do: {indices, Map.take(inherited_weights, indices)}

  defp event_source_indices(state, events) do
    index_by_id =
      state.agents
      |> Enum.with_index()
      |> Map.new(fn {agent, index} -> {agent["id"], index} end)

    events
    |> Enum.flat_map(fn event ->
      cond do
        is_list(event["source_indices"]) ->
          event["source_indices"]

        is_integer(event["agent_index"]) ->
          [event["agent_index"]]

        is_integer(index_by_id[event["actor"]]) ->
          [index_by_id[event["actor"]]]

        true ->
          audience_indices(state.agents, event["audience"] || %{})
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp neighbor_indices(state, source_indices, type, limit) do
    source_ids =
      state.agents
      |> selected_agents(source_indices)
      |> MapSet.new(& &1["id"])

    {_counts, selected} =
      state.relationships
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
      state.agents
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
    |> then(fn rows -> {Enum.map(rows, &elem(&1, 0)), Map.new(rows)} end)
  end

  defp select_neighbor(counts, selected, source_ids, source, target, weight, limit) do
    count = counts[source] || 0

    if MapSet.member?(source_ids, source) and count < limit do
      {Map.put(counts, source, count + 1), Map.put_new(selected, target, weight)}
    else
      {counts, selected}
    end
  end

  defp first_weight(weights) do
    weights
    |> Enum.sort_by(&elem(&1, 0))
    |> List.first()
    |> case do
      {_index, weight} -> weight
      nil -> nil
    end
  end

  defp all_indices([]), do: []
  defp all_indices(agents), do: Enum.to_list(0..(length(agents) - 1))

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

  defp transfer_preview(_state, _resource, nil, _to, _amount),
    do: {:error, preview_error("missing_transfer_account", "a transfer source is unavailable")}

  defp transfer_preview(_state, _resource, _from, nil, _amount),
    do:
      {:error, preview_error("missing_transfer_account", "a transfer destination is unavailable")}

  defp transfer_preview(_state, _resource, account, account, _amount),
    do: {:error, preview_error("invalid_transfer", "a transfer must move between two accounts")}

  defp transfer_preview(state, resource, from, to, amount) do
    source_balance = preview_balance(state, from, resource)

    if source_balance < amount do
      {:error,
       preview_error(
         "insufficient_resource",
         "a representative account cannot satisfy a declared transfer"
       )}
    else
      next =
        state
        |> put_preview_balance(from, resource, round_number(source_balance - amount))
        |> put_preview_balance(
          to,
          resource,
          round_number(preview_balance(state, to, resource) + amount)
        )

      {:ok, %{next | state_changes: next.state_changes + 1}}
    end
  end

  defp preview_balance(state, :world, resource), do: number(state.world_resources[resource])

  defp preview_balance(state, {:agent, index}, resource),
    do: state.agents |> Enum.at(index) |> get_in(["resources", resource]) |> number()

  defp put_preview_balance(state, :world, resource, balance),
    do: %{state | world_resources: Map.put(state.world_resources, resource, balance)}

  defp put_preview_balance(state, {:agent, index}, resource, balance) do
    agents =
      List.update_at(state.agents, index, &put_in(&1, ["resources", resource], balance))

    %{state | agents: agents}
  end

  defp preview_account("agent", agent_index, _target_index), do: {:agent, agent_index}
  defp preview_account("world", _agent_index, _target_index), do: :world
  defp preview_account("target", _agent_index, nil), do: nil
  defp preview_account("target", _agent_index, target_index), do: {:agent, target_index}
  defp preview_account(_kind, _agent_index, _target_index), do: nil

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

  defp comparable?(left, right), do: is_number(left) and is_number(right)
  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: 0.0
  defp round_number(value) when is_integer(value), do: value
  defp round_number(value) when is_float(value), do: Float.round(value, 6)
  defp round_number(value), do: value

  defp sanitize_errors(errors) do
    Enum.map(errors, fn error ->
      %{
        "path" => error["path"] || "$",
        "code" => error["code"] || "invalid_script",
        "message" => error["message"] || "the script is invalid"
      }
    end)
  end

  defp failed(rounds, agents, seed, errors) do
    summary = %{"rounds_completed" => 0, "agent_count" => agents, "model_calls" => 0}

    {:error,
     %{
       status: "failed",
       rounds_requested: rounds,
       rounds_completed: 0,
       agent_count: agents,
       seed: seed,
       summary: summary,
       errors: errors,
       result_hash: ContentHash.digest(%{"summary" => summary, "errors" => errors})
     }}
  end

  defp preview_error(code, message), do: %{"path" => "$", "code" => code, "message" => message}
end
