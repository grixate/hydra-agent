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
         {:ok, result} <- execute(script, agents, rounds, seed) do
      summary = %{
        "rounds_completed" => rounds,
        "agent_count" => length(agents),
        "model_calls" => 0,
        "action_counts" => result.action_counts,
        "event_count" => length(result.events),
        "state_change_count" => result.state_changes,
        "observations" => result.observations,
        "world_state" => result.world,
        "final_agent_state_hash" => ContentHash.digest(result.agents)
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

  defp execute(script, agents, rounds, seed) do
    initial = %{
      agents: agents,
      world: get_in(script, ["world", "state"]) || %{},
      events: [],
      action_counts: %{},
      state_changes: 0,
      observations: []
    }

    Enum.reduce_while(1..rounds, {:ok, initial}, fn round, {:ok, state} ->
      with {:ok, state} <- apply_scheduled_events(script, state, round, "before_actions"),
           {:ok, state} <- run_actions(script, state, round, seed),
           {:ok, state} <- apply_scheduled_events(script, state, round, "after_actions"),
           {:ok, state} <- apply_transitions(script, state),
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

  defp apply_scheduled_events(script, state, round, phase) do
    script
    |> Map.get("events", [])
    |> Enum.filter(&(&1["at_round"] == round and &1["phase"] == phase))
    |> Enum.reduce_while({:ok, state}, fn event, {:ok, current} ->
      case apply_event(event, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_event(event, state) do
    audience = audience_indices(state.agents, event["audience"] || %{})

    with {:ok, next} <- apply_effects(event["effects"] || [], state, audience) do
      {:ok, %{next | events: next.events ++ [%{"type" => event["id"], "payload" => %{}}]}}
    end
  end

  defp run_actions(script, state, round, seed) do
    assignments = Map.new(script["agent_types"] || [], &{&1["id"], &1["policy"]})
    policies = Map.new(script["policies"] || [], &{&1["id"], &1})
    actions = Map.new(script["actions"] || [], &{&1["id"], &1})

    state.agents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {agent, index}, {:ok, current} ->
      facts = %{agent: agent, world: current.world, decision: %{"uncertainty" => 0.0}}

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

  defp apply_effects(effects, state, audience_indices) do
    Enum.reduce_while(effects, {:ok, state}, fn effect, {:ok, current} ->
      case apply_effect(effect, current, audience_indices) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_effect(%{"op" => "set_world", "path" => path, "value" => value}, state, _indices) do
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
         _indices
       ) do
    previous = state.world[path] || 0
    amount = numeric(expression, %{world: state.world, agent: %{}, decision: %{}})
    value = round_number(previous + amount)

    {:ok,
     %{state | world: Map.put(state.world, path, value), state_changes: state.state_changes + 1}}
  end

  defp apply_effect(
         %{"op" => "set_agent", "path" => "state." <> path, "value" => value},
         state,
         indices
       ) do
    agents =
      update_agents(state.agents, indices, fn agent -> put_in(agent, ["state", path], value) end)

    {:ok, %{state | agents: agents, state_changes: state.state_changes + length(indices)}}
  end

  defp apply_effect(
         %{"op" => "adjust_attribute", "path" => path, "value" => expression},
         state,
         indices
       ) do
    attribute = String.replace_prefix(path, "attributes.", "")

    agents =
      update_agents(state.agents, indices, fn agent ->
        facts = %{agent: agent, world: state.world, decision: %{}}
        previous = get_in(agent, ["attributes", attribute]) || 0

        put_in(
          agent,
          ["attributes", attribute],
          round_number(previous + numeric(expression, facts))
        )
      end)

    {:ok, %{state | agents: agents, state_changes: state.state_changes + length(indices)}}
  end

  defp apply_effect(
         %{"op" => "adjust_resource", "resource" => resource, "amount" => expression},
         state,
         indices
       ) do
    agents =
      update_agents(state.agents, indices, fn agent ->
        facts = %{agent: agent, world: state.world, decision: %{}}
        previous = get_in(agent, ["resources", resource]) || 0

        put_in(
          agent,
          ["resources", resource],
          round_number(previous + numeric(expression, facts))
        )
      end)

    {:ok, %{state | agents: agents, state_changes: state.state_changes + length(indices)}}
  end

  defp apply_effect(%{"op" => op}, state, _indices)
       when op in ~w(transfer_resource set_relationship adjust_relationship),
       do: {:ok, state}

  defp apply_effect(_effect, _state, _indices),
    do:
      {:error,
       preview_error("unsupported_preview_effect", "the preview cannot apply one declared effect")}

  defp apply_transitions(script, state) do
    recent_types = MapSet.new(state.events, & &1["type"])

    script
    |> Map.get("transitions", [])
    |> Enum.filter(&MapSet.member?(recent_types, get_in(&1, ["when", "event_type"])))
    |> Enum.reduce_while({:ok, state}, fn transition, {:ok, current} ->
      indices = transition_target_indices(transition["target"] || %{}, current)

      with {:ok, effected} <- apply_effects(transition["effects"] || [], current, indices) do
        emissions =
          Enum.map(transition["emits"] || [], fn emission ->
            %{"type" => emission["type"], "payload" => emission["payload"] || %{}}
          end)

        {:cont, {:ok, %{effected | events: effected.events ++ emissions}}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp transition_target_indices(%{"self" => true}, _state), do: [0]

  defp transition_target_indices(%{"audience" => true}, state),
    do: Enum.to_list(0..(length(state.agents) - 1))

  defp transition_target_indices(_target, _state), do: []

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
  defp metric_value(%{"kind" => "relationship_count"}, _state), do: 0
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

  defp fact_value("world." <> key, facts), do: get_in(facts, [:world, key])

  defp fact_value("agent.attributes." <> key, facts),
    do: get_in(facts, [:agent, "attributes", key])

  defp fact_value("agent.state." <> key, facts), do: get_in(facts, [:agent, "state", key])
  defp fact_value("agent.resources." <> key, facts), do: get_in(facts, [:agent, "resources", key])
  defp fact_value("decision.uncertainty", facts), do: get_in(facts, [:decision, "uncertainty"])
  defp fact_value(_fact, _facts), do: nil

  defp audience_indices(agents, %{"all" => true}), do: Enum.to_list(0..(length(agents) - 1))

  defp audience_indices(agents, %{"agent_type" => type}) do
    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} -> if agent["type"] == type, do: [index], else: [] end)
  end

  defp audience_indices(_agents, _audience), do: []

  defp update_agents(agents, indices, update) do
    selected = MapSet.new(indices)

    agents
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      if MapSet.member?(selected, index), do: update.(agent), else: agent
    end)
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
