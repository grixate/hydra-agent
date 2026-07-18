defmodule HydraAgent.Simulations.ScriptValidator do
  @moduledoc "Semantic validator for the declarative Simulation Script V1 contract."

  alias HydraAgent.Simulations.PopulationModel

  @id_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @phases ~w(before_actions after_actions)
  @condition_operators ~w(eq neq gt gte lt lte in not_in exists)
  @numeric_operators ~w(add subtract multiply divide min max clamp)
  @policy_kinds ~w(fixed weighted rule_set hybrid)
  @effect_ops ~w(set_world adjust_world set_agent adjust_attribute adjust_resource transfer_resource set_relationship adjust_relationship)
  @metric_kinds ~w(agent_fraction mean action_count resource_sum relationship_count world_value)
  @stopping_kinds ~w(final_round no_state_changes budget_exhausted metric_threshold explicit_cancel)

  @max_rounds 200
  @max_world_keys 64
  @max_resources 32
  @max_events 256
  @max_actions 64
  @max_policies 64
  @max_transitions 128
  @max_metrics 64
  @max_expression_depth 8
  @max_expression_nodes 64
  @max_estimated_operations 200_000_000

  def validate(script, population_model, opts \\ [])

  def validate(script, %PopulationModel{} = population_model, opts),
    do: validate(script, PopulationModel.contract(population_model), opts)

  def validate(script, population, opts) when is_map(script) and is_map(population) do
    model_budget? = Keyword.get(opts, :model_budget?, false)
    type_ids = population |> list("agent_types") |> ids()
    archetypes = list(population, "archetypes")
    resources = list(script, "resources")
    actions = list(script, "actions")
    events = list(script, "events")
    policies = list(script, "policies")
    transitions = list(script, "transitions")
    metrics = script |> value("observations", %{}) |> list("metrics")

    resource_ids = ids(resources)
    action_ids = ids(actions)
    event_ids = ids(events)
    policy_ids = ids(policies)
    relationship_ids = script |> list("relationships") |> ids()
    metric_ids = ids(metrics)

    declared_event_types =
      (event_ids ++ emitted_types(actions) ++ emitted_types(transitions))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    fact_context = fact_context(script, population)

    errors =
      []
      |> require_equal(value(script, "hydra_simulation_script"), 1, "$.hydra_simulation_script")
      |> require_map(value(script, "metadata"), "$.metadata")
      |> require_map(value(script, "clock"), "$.clock")
      |> require_map(value(script, "world"), "$.world")
      |> require_list(value(script, "agent_types"), "$.agent_types")
      |> require_list(value(script, "relationships"), "$.relationships")
      |> require_list(value(script, "resources"), "$.resources")
      |> require_list(value(script, "events"), "$.events")
      |> require_list(value(script, "actions"), "$.actions")
      |> require_map(value(script, "perception"), "$.perception")
      |> require_list(value(script, "policies"), "$.policies")
      |> require_list(value(script, "transitions"), "$.transitions")
      |> require_map(value(script, "observations"), "$.observations")
      |> require_list(value(script, "stopping_conditions"), "$.stopping_conditions")

    errors =
      errors ++
        validate_metadata(value(script, "metadata")) ++
        validate_clock(value(script, "clock")) ++
        validate_world(value(script, "world"), resources) ++
        validate_script_agent_types(
          list(script, "agent_types"),
          type_ids,
          policy_ids,
          Map.keys(value(script, "perception", %{}))
        ) ++
        validate_relationships(list(script, "relationships"), type_ids) ++
        validate_resources(resources) ++
        validate_events(
          events,
          value(script, "clock", %{}),
          type_ids,
          resource_ids,
          relationship_ids,
          fact_context
        ) ++
        validate_actions(actions, type_ids, resource_ids, relationship_ids, fact_context) ++
        validate_perception(
          value(script, "perception"),
          fact_context,
          relationship_ids,
          event_ids
        ) ++
        validate_policies(policies, action_ids, policy_ids, fact_context, model_budget?) ++
        validate_transitions(
          transitions,
          declared_event_types,
          relationship_ids,
          resource_ids,
          fact_context
        ) ++
        validate_observations(
          value(script, "observations"),
          action_ids,
          resource_ids,
          fact_context
        ) ++
        validate_stopping_conditions(
          list(script, "stopping_conditions"),
          value(script, "clock", %{}),
          metric_ids
        ) ++
        duplicate_errors(type_ids_from_script(script), "$.agent_types", "agent type") ++
        duplicate_errors(relationship_ids, "$.relationships", "relationship") ++
        duplicate_errors(resource_ids, "$.resources", "resource") ++
        duplicate_errors(event_ids, "$.events", "event") ++
        duplicate_errors(action_ids, "$.actions", "action") ++
        duplicate_errors(policy_ids, "$.policies", "policy") ++
        duplicate_errors(ids(transitions), "$.transitions", "transition") ++
        duplicate_errors(metric_ids, "$.observations.metrics", "metric") ++
        validate_resource_feasibility(actions, resources, archetypes) ++
        validate_action_reachability(script, actions, policies) ++
        validate_event_cycles(transitions)

    complexity = complexity_report(script, population)

    errors =
      if complexity["estimated_operations"] > @max_estimated_operations do
        [
          error(
            "$",
            "complexity_limit_exceeded",
            "the estimated execution work exceeds the deployment limit"
          )
          | errors
        ]
      else
        errors
      end

    case Enum.take(errors, 500) do
      [] ->
        {:ok,
         %{
           "schema_version" => 1,
           "semantic_status" => "valid",
           "error_count" => 0,
           "validated_sections" => 13,
           "complexity" => complexity,
           "model_escalation" => Enum.any?(policies, &(value(&1, "kind") == "hybrid")),
           "arbitrary_code" => false
         }}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate(_script, _population, _opts),
    do: {:error, [error("$", "invalid_script", "must be an object")]}

  defp validate_metadata(metadata) when is_map(metadata) do
    []
    |> require_id(value(metadata, "id"), "$.metadata.id")
    |> require_string(value(metadata, "title"), "$.metadata.title", 3, 180)
    |> require_in(value(metadata, "locale"), ~w(en ru), "$.metadata.locale")
  end

  defp validate_metadata(_metadata), do: []

  defp validate_clock(clock) when is_map(clock) do
    []
    |> require_equal(value(clock, "kind"), "rounds", "$.clock.kind")
    |> require_integer(value(clock, "count"), "$.clock.count", 1, @max_rounds)
    |> require_string(value(clock, "label"), "$.clock.label", 1, 40)
  end

  defp validate_clock(_clock), do: []

  defp validate_world(world, resource_definitions) when is_map(world) do
    state = value(world, "state")
    resources = value(world, "resources", %{})

    []
    |> require_map(state, "$.world.state")
    |> require_map(resources, "$.world.resources")
    |> then(fn errors ->
      if is_map(state) and map_size(state) > @max_world_keys,
        do: [error("$.world.state", "too_many_values", "supports at most 64 values") | errors],
        else: errors
    end)
    |> then(fn errors ->
      if is_map(state),
        do:
          errors ++
            (state
             |> Enum.flat_map(fn {key, nested} ->
               []
               |> require_id(key, "$.world.state.#{key}")
               |> then(
                 &if json_value?(nested, 0),
                   do: &1,
                   else: [
                     error(
                       "$.world.state.#{key}",
                       "invalid_value",
                       "must be bounded JSON data"
                     )
                     | &1
                   ]
               )
             end)),
        else: errors
    end)
    |> Kernel.++(validate_world_resources(resources, resource_definitions))
  end

  defp validate_world(_world, _resource_definitions), do: []

  defp validate_world_resources(resources, definitions) when is_map(resources) do
    definitions = Map.new(definitions, &{value(&1, "id"), &1})

    Enum.flat_map(resources, fn {resource_id, balance} ->
      path = "$.world.resources.#{resource_id}"

      case definitions[resource_id] do
        nil ->
          [error(path, "missing_reference", "does not reference a declared resource")]

        definition ->
          constraints = value(definition, "constraints", %{})
          minimum = value(constraints, "min")
          maximum = value(constraints, "max")

          cond do
            not is_number(balance) ->
              [error(path, "invalid_number", "must be a number")]

            is_number(minimum) and balance < minimum ->
              [error(path, "below_minimum", "must respect the declared minimum")]

            is_number(maximum) and balance > maximum ->
              [error(path, "above_maximum", "must respect the declared maximum")]

            true ->
              []
          end
      end
    end)
  end

  defp validate_world_resources(_resources, _definitions), do: []

  defp validate_script_agent_types(agent_types, population_type_ids, policy_ids, perception_ids) do
    agent_types
    |> Enum.with_index()
    |> Enum.flat_map(fn {type, index} ->
      path = "$.agent_types[#{index}]"

      []
      |> require_map(type, path)
      |> require_member(value(type, "id"), population_type_ids, "#{path}.id")
      |> require_member(value(type, "policy"), policy_ids, "#{path}.policy")
      |> require_member(value(type, "perception"), perception_ids, "#{path}.perception")
    end)
    |> then(fn errors ->
      declared = MapSet.new(type_ids_from_items(agent_types))
      expected = MapSet.new(population_type_ids)

      if declared == expected,
        do: errors,
        else: [
          error(
            "$.agent_types",
            "agent_type_coverage",
            "must assign a policy and perception to every population agent type"
          )
          | errors
        ]
    end)
  end

  defp validate_relationships(relationships, type_ids) do
    relationships
    |> count_errors("$.relationships", 0, 32)
    |> Kernel.++(
      relationships
      |> Enum.with_index()
      |> Enum.flat_map(fn {relationship, index} ->
        path = "$.relationships[#{index}]"

        []
        |> require_map(relationship, path)
        |> require_id(value(relationship, "id"), "#{path}.id")
        |> then(
          &(&1 ++
              string_list_members(
                value(relationship, "source_types"),
                type_ids,
                "#{path}.source_types",
                1,
                16
              ))
        )
        |> then(
          &(&1 ++
              string_list_members(
                value(relationship, "target_types"),
                type_ids,
                "#{path}.target_types",
                1,
                16
              ))
        )
        |> require_boolean(value(relationship, "directed"), "#{path}.directed")
      end)
    )
  end

  defp validate_resources(resources) do
    resources
    |> count_errors("$.resources", 0, @max_resources)
    |> Kernel.++(
      resources
      |> Enum.with_index()
      |> Enum.flat_map(fn {resource, index} ->
        path = "$.resources[#{index}]"
        constraints = value(resource, "constraints", %{})
        min_value = value(constraints, "min")
        max_value = value(constraints, "max")

        errors =
          []
          |> require_map(resource, path)
          |> require_id(value(resource, "id"), "#{path}.id")
          |> require_string(value(resource, "unit"), "#{path}.unit", 1, 40)
          |> require_integer(value(resource, "precision"), "#{path}.precision", 0, 8)
          |> require_map(constraints, "#{path}.constraints")
          |> optional_number(min_value, "#{path}.constraints.min", -1_000_000, 1_000_000)
          |> optional_number(max_value, "#{path}.constraints.max", -1_000_000, 1_000_000)

        errors =
          errors
          |> optional_string(value(resource, "label"), "#{path}.label", 1, 80)
          |> optional_boolean(value(resource, "allow_negative"), "#{path}.allow_negative")
          |> optional_boolean(value(resource, "mint_allowed"), "#{path}.mint_allowed")
          |> optional_boolean(value(resource, "burn_allowed"), "#{path}.burn_allowed")
          |> optional_member(
            value(resource, "visibility"),
            ~w(private participants public),
            "#{path}.visibility"
          )
          |> optional_member(
            value(resource, "aggregation"),
            ~w(sum mean min max none),
            "#{path}.aggregation"
          )

        if is_number(min_value) and is_number(max_value) and min_value > max_value,
          do: [error("#{path}.constraints", "invalid_bounds", "minimum exceeds maximum") | errors],
          else: errors
      end)
    )
  end

  defp validate_events(
         events,
         clock,
         type_ids,
         resource_ids,
         relationship_ids,
         fact_context
       ) do
    round_count = value(clock, "count", 0)

    events
    |> count_errors("$.events", 0, @max_events)
    |> Kernel.++(
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn {event, index} ->
        path = "$.events[#{index}]"
        audience = value(event, "audience", %{})

        []
        |> require_map(event, path)
        |> require_id(value(event, "id"), "#{path}.id")
        |> require_integer(value(event, "at_round"), "#{path}.at_round", 1, max(round_count, 1))
        |> require_in(value(event, "phase"), @phases, "#{path}.phase")
        |> then(&(&1 ++ validate_audience(audience, type_ids, "#{path}.audience")))
        |> then(
          &(&1 ++
              validate_effects(
                value(event, "effects", []),
                resource_ids,
                relationship_ids,
                fact_context,
                "#{path}.effects"
              ))
        )
      end)
    )
  end

  defp validate_actions(actions, type_ids, resource_ids, relationship_ids, fact_context) do
    actions
    |> count_errors("$.actions", 1, @max_actions)
    |> Kernel.++(
      actions
      |> Enum.with_index()
      |> Enum.flat_map(fn {action, index} ->
        path = "$.actions[#{index}]"

        []
        |> require_map(action, path)
        |> require_id(value(action, "id"), "#{path}.id")
        |> then(
          &(&1 ++
              string_list_members(value(action, "actors"), type_ids, "#{path}.actors", 1, 16))
        )
        |> then(
          &(&1 ++
              validate_optional_condition(
                value(action, "preconditions"),
                fact_context,
                "#{path}.preconditions"
              ))
        )
        |> then(&(&1 ++ validate_costs(value(action, "costs", []), resource_ids, path)))
        |> then(
          &(&1 ++
              validate_effects(
                value(action, "effects", []),
                resource_ids,
                relationship_ids,
                fact_context,
                "#{path}.effects"
              ))
        )
        |> then(&(&1 ++ validate_emits(value(action, "emits", []), "#{path}.emits")))
      end)
    )
  end

  defp validate_perception(perception, fact_context, relationship_ids, event_ids)
       when is_map(perception) do
    if map_size(perception) > 32 do
      [error("$.perception", "too_many_views", "supports at most 32 perception views")]
    else
      perception
      |> Enum.flat_map(fn {id, view} ->
        path = "$.perception.#{id}"
        relationships = value(view, "relationships", %{})
        recent = value(view, "recent_events", %{})

        []
        |> require_id(id, path)
        |> require_map(view, path)
        |> then(
          &(&1 ++
              string_list_members(
                value(view, "world", []),
                fact_context.world,
                "#{path}.world",
                0,
                64
              ))
        )
        |> then(
          &(&1 ++
              string_list_members(
                value(view, "self", []),
                ~w(attributes state resources goals constraints),
                "#{path}.self",
                1,
                8
              ))
        )
        |> require_map(relationships, "#{path}.relationships")
        |> then(
          &(&1 ++
              string_list_members(
                value(relationships, "types", []),
                relationship_ids,
                "#{path}.relationships.types",
                0,
                32
              ))
        )
        |> require_integer(
          value(relationships, "limit", 0),
          "#{path}.relationships.limit",
          0,
          100
        )
        |> require_map(recent, "#{path}.recent_events")
        |> then(
          &(&1 ++
              validate_string_list(value(recent, "types", []), "#{path}.recent_events.types", 64))
        )
        |> require_integer(value(recent, "rounds", 0), "#{path}.recent_events.rounds", 0, 20)
        |> require_integer(value(recent, "limit", 0), "#{path}.recent_events.limit", 0, 200)
        |> then(fn errors ->
          declared = MapSet.new(event_ids)

          unknown =
            recent
            |> value("types", [])
            |> Enum.reject(&(MapSet.member?(declared, &1) or valid_id?(&1)))

          if unknown == [],
            do: errors,
            else: [
              error(
                "#{path}.recent_events.types",
                "invalid_event_type",
                "contains an invalid event type"
              )
              | errors
            ]
        end)
      end)
    end
  end

  defp validate_perception(_perception, _fact_context, _relationship_ids, _event_ids), do: []

  defp validate_policies(policies, action_ids, policy_ids, fact_context, model_budget?) do
    policies
    |> count_errors("$.policies", 1, @max_policies)
    |> Kernel.++(
      policies
      |> Enum.with_index()
      |> Enum.flat_map(fn {policy, index} ->
        path = "$.policies[#{index}]"
        kind = value(policy, "kind")

        errors =
          []
          |> require_map(policy, path)
          |> require_id(value(policy, "id"), "#{path}.id")
          |> require_in(kind, @policy_kinds, "#{path}.kind")

        errors ++
          case kind do
            "fixed" ->
              []
              |> require_member(value(policy, "action"), action_ids, "#{path}.action")

            "weighted" ->
              candidates = value(policy, "candidates")

              []
              |> require_map(candidates, "#{path}.candidates")
              |> then(
                &(&1 ++
                    validate_weighted_candidates(candidates, action_ids, fact_context, path))
              )

            "rule_set" ->
              rules = value(policy, "rules")

              []
              |> require_list(rules, "#{path}.rules")
              |> require_member(value(policy, "fallback"), action_ids, "#{path}.fallback")
              |> then(&(&1 ++ validate_policy_rules(rules, action_ids, fact_context, path)))

            "hybrid" ->
              []
              |> require_member(value(policy, "fallback"), policy_ids, "#{path}.fallback")
              |> then(
                &(&1 ++
                    string_list_members(
                      value(policy, "candidates"),
                      action_ids,
                      "#{path}.candidates",
                      1,
                      @max_actions
                    ))
              )
              |> then(
                &(&1 ++
                    validate_condition(
                      value(policy, "escalate_when"),
                      fact_context,
                      "#{path}.escalate_when"
                    ))
              )
              |> require_equal(value(policy, "model_role"), "simulation", "#{path}.model_role")
              |> then(fn current ->
                if model_budget?,
                  do: current,
                  else: [
                    error(
                      path,
                      "model_budget_required",
                      "hybrid policy requires an explicit simulation model budget"
                    )
                    | current
                  ]
              end)

            _ ->
              []
          end
      end)
    )
  end

  defp validate_transitions(transitions, event_ids, relationship_ids, resource_ids, fact_context) do
    transitions
    |> count_errors("$.transitions", 0, @max_transitions)
    |> Kernel.++(
      transitions
      |> Enum.with_index()
      |> Enum.flat_map(fn {transition, index} ->
        path = "$.transitions[#{index}]"
        when_clause = value(transition, "when", %{})
        target = value(transition, "target", %{})

        []
        |> require_map(transition, path)
        |> require_id(value(transition, "id"), "#{path}.id")
        |> require_map(when_clause, "#{path}.when")
        |> require_member(value(when_clause, "event_type"), event_ids, "#{path}.when.event_type")
        |> then(
          &(&1 ++
              validate_json_value(
                value(when_clause, "payload", %{}),
                "#{path}.when.payload"
              ))
        )
        |> then(&(&1 ++ validate_target(target, relationship_ids, "#{path}.target")))
        |> then(
          &(&1 ++
              validate_effects(
                value(transition, "effects", []),
                resource_ids,
                relationship_ids,
                fact_context,
                "#{path}.effects"
              ))
        )
        |> then(&(&1 ++ validate_emits(value(transition, "emits", []), "#{path}.emits")))
      end)
    )
  end

  defp validate_observations(observations, action_ids, resource_ids, fact_context)
       when is_map(observations) do
    metrics = list(observations, "metrics")
    traces = value(observations, "traces", %{})

    metrics
    |> count_errors("$.observations.metrics", 1, @max_metrics)
    |> Kernel.++(
      metrics
      |> Enum.with_index()
      |> Enum.flat_map(fn {metric, index} ->
        path = "$.observations.metrics[#{index}]"
        kind = value(metric, "kind")

        errors =
          []
          |> require_map(metric, path)
          |> require_id(value(metric, "id"), "#{path}.id")
          |> require_in(kind, @metric_kinds, "#{path}.kind")

        errors ++ validate_metric(metric, kind, action_ids, resource_ids, fact_context, path)
      end)
    )
    |> require_map(traces, "$.observations.traces")
    |> optional_integer(
      value(traces, "representatives_per_archetype"),
      "$.observations.traces.representatives_per_archetype",
      0,
      5
    )
    |> optional_integer(
      value(traces, "high_influence"),
      "$.observations.traces.high_influence",
      0,
      20
    )
    |> optional_integer(value(traces, "outliers"), "$.observations.traces.outliers", 0, 20)
  end

  defp validate_observations(_observations, _actions, _resources, _facts), do: []

  defp validate_stopping_conditions(conditions, clock, metric_ids) do
    errors =
      conditions
      |> count_errors("$.stopping_conditions", 1, 8)
      |> Kernel.++(
        conditions
        |> Enum.with_index()
        |> Enum.flat_map(fn {condition, index} ->
          path = "$.stopping_conditions[#{index}]"
          kind = value(condition, "kind")

          errors =
            []
            |> require_map(condition, path)
            |> require_in(kind, @stopping_kinds, "#{path}.kind")

          errors ++
            case kind do
              "no_state_changes" ->
                require_integer(
                  [],
                  value(condition, "rounds"),
                  "#{path}.rounds",
                  1,
                  max(value(clock, "count", 1), 1)
                )

              "metric_threshold" ->
                []
                |> require_member(value(condition, "metric"), metric_ids, "#{path}.metric")
                |> require_in(value(condition, "op"), ~w(gt gte lt lte eq), "#{path}.op")
                |> require_number(
                  value(condition, "value"),
                  "#{path}.value",
                  -1_000_000,
                  1_000_000
                )

              _ ->
                []
            end
        end)
      )

    if Enum.any?(conditions, &(value(&1, "kind") == "final_round")),
      do: errors,
      else: [
        error(
          "$.stopping_conditions",
          "final_round_required",
          "must include a final-round boundary"
        )
        | errors
      ]
  end

  defp validate_resource_feasibility(actions, resources, archetypes) do
    definitions = Map.new(resources, &{value(&1, "id"), &1})

    actions
    |> Enum.with_index()
    |> Enum.flat_map(fn {action, action_index} ->
      actors = MapSet.new(value(action, "actors", []))

      action
      |> list("costs")
      |> Enum.with_index()
      |> Enum.flat_map(fn {cost, cost_index} ->
        resource = value(cost, "resource")
        amount = value(cost, "amount")
        definition = definitions[resource] || %{}
        minimum = value(value(definition, "constraints", %{}), "min")

        available =
          archetypes
          |> Enum.filter(&MapSet.member?(actors, value(&1, "agent_type")))
          |> Enum.map(&value(value(&1, "initial_resources", %{}), resource, 0))

        path = "$.actions[#{action_index}].costs[#{cost_index}]"

        []
        |> then(fn errors ->
          if value(definition, "burn_allowed", true) == false and is_number(amount) and
               amount > 0 do
            [
              error(
                path,
                "burn_not_allowed",
                "the declared resource does not allow action-cost consumption"
              )
              | errors
            ]
          else
            errors
          end
        end)
        |> then(fn errors ->
          if minimum == 0 and is_number(amount) and available != [] and
               Enum.any?(available, &(not is_number(&1) or &1 < amount)) do
            [
              error(
                path,
                "negative_balance_possible",
                "at least one eligible archetype cannot pay this non-negative resource cost"
              )
              | errors
            ]
          else
            errors
          end
        end)
      end)
    end)
  end

  defp validate_action_reachability(script, actions, policies) do
    policies_by_id = Map.new(policies, &{value(&1, "id"), &1})
    assignments = Map.new(list(script, "agent_types"), &{value(&1, "id"), value(&1, "policy")})

    actions
    |> Enum.with_index()
    |> Enum.flat_map(fn {action, index} ->
      action_id = value(action, "id")

      reachable? =
        action
        |> value("actors", [])
        |> Enum.any?(fn type_id ->
          policy_actions(assignments[type_id], policies_by_id, MapSet.new())
          |> MapSet.member?(action_id)
        end)

      if reachable?,
        do: [],
        else: [
          error(
            "$.actions[#{index}]",
            "unreachable_action",
            "no eligible agent policy can select this action"
          )
        ]
    end)
  end

  defp policy_actions(nil, _policies, _visited), do: MapSet.new()

  defp policy_actions(policy_id, policies, visited) do
    if MapSet.member?(visited, policy_id) do
      MapSet.new()
    else
      visited = MapSet.put(visited, policy_id)
      policy = policies[policy_id] || %{}

      direct =
        case value(policy, "kind") do
          "fixed" ->
            [value(policy, "action")]

          "weighted" ->
            policy |> value("candidates", %{}) |> Map.keys()

          "rule_set" ->
            [value(policy, "fallback") | Enum.map(list(policy, "rules"), &value(&1, "action"))]

          "hybrid" ->
            value(policy, "candidates", [])

          _ ->
            []
        end
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      case value(policy, "kind") do
        "hybrid" ->
          MapSet.union(direct, policy_actions(value(policy, "fallback"), policies, visited))

        _ ->
          direct
      end
    end
  end

  defp validate_event_cycles(transitions) do
    graph =
      transitions
      |> Enum.reduce(%{}, fn transition, acc ->
        source = get_in(transition, ["when", "event_type"])

        emitted =
          transition |> list("emits") |> Enum.map(&value(&1, "type")) |> Enum.reject(&is_nil/1)

        Map.update(acc, source, emitted, &Enum.uniq(&1 ++ emitted))
      end)

    if Enum.any?(Map.keys(graph), &cycle_from?(&1, graph, MapSet.new(), MapSet.new())) do
      [
        error(
          "$.transitions",
          "unbounded_event_cycle",
          "same-phase transition emissions must not form a cycle"
        )
      ]
    else
      []
    end
  end

  defp emitted_types(records) do
    Enum.flat_map(records, fn record ->
      record
      |> list("emits")
      |> Enum.map(&value(&1, "type"))
    end)
  end

  defp cycle_from?(nil, _graph, _visiting, _visited), do: false

  defp cycle_from?(node, graph, visiting, visited) do
    cond do
      MapSet.member?(visiting, node) ->
        true

      MapSet.member?(visited, node) ->
        false

      true ->
        visiting = MapSet.put(visiting, node)
        Enum.any?(graph[node] || [], &cycle_from?(&1, graph, visiting, MapSet.put(visited, node)))
    end
  end

  defp validate_audience(%{"all" => true}, _type_ids, _path), do: []

  defp validate_audience(audience, type_ids, path) when is_map(audience) do
    require_member([], value(audience, "agent_type"), type_ids, "#{path}.agent_type")
  end

  defp validate_audience(_audience, _type_ids, path),
    do: [error(path, "invalid_audience", "must target all agents or one agent type")]

  defp validate_costs(costs, resource_ids, action_path) do
    errors = count_errors(list_value(costs), "#{action_path}.costs", 0, 16)

    errors ++
      (costs
       |> list_value()
       |> Enum.with_index()
       |> Enum.flat_map(fn {cost, index} ->
         path = "#{action_path}.costs[#{index}]"

         []
         |> require_map(cost, path)
         |> require_member(value(cost, "resource"), resource_ids, "#{path}.resource")
         |> require_number(value(cost, "amount"), "#{path}.amount", 0, 1_000_000)
       end))
  end

  defp validate_effects(effects, resource_ids, relationship_ids, fact_context, path) do
    effects = list_value(effects)

    count_errors(effects, path, 0, 32) ++
      (effects
       |> Enum.with_index()
       |> Enum.flat_map(fn {effect, index} ->
         effect_path = "#{path}[#{index}]"
         op = value(effect, "op")

         errors =
           []
           |> require_map(effect, effect_path)
           |> require_in(op, @effect_ops, "#{effect_path}.op")

         errors ++
           validate_effect(effect, op, resource_ids, relationship_ids, fact_context, effect_path)
       end))
  end

  defp validate_effect(effect, op, _resource_ids, _relationship_ids, fact_context, path)
       when op in ~w(set_world adjust_world) do
    []
    |> require_member(value(effect, "path"), fact_context.world, "#{path}.path")
    |> then(
      &(&1 ++
          if(op == "adjust_world",
            do:
              validate_numeric_expression(value(effect, "value"), fact_context, "#{path}.value"),
            else: validate_json_value(value(effect, "value"), "#{path}.value")
          ))
    )
  end

  defp validate_effect(effect, op, _resources, _relationships, fact_context, path)
       when op in ~w(set_agent adjust_attribute) do
    effect_path = value(effect, "path")

    errors =
      []
      |> require_string(effect_path, "#{path}.path", 3, 120)
      |> require_member(
        effect_path,
        declared_agent_effect_paths(op, fact_context),
        "#{path}.path"
      )

    errors ++
      if(op == "adjust_attribute",
        do: validate_numeric_expression(value(effect, "value"), fact_context, "#{path}.value"),
        else: validate_json_value(value(effect, "value"), "#{path}.value")
      ) ++ validate_optional_target(effect, fact_context.relationships, path)
  end

  defp validate_effect(
         effect,
         "adjust_resource",
         resource_ids,
         _relationships,
         fact_context,
         path
       ) do
    []
    |> require_member(value(effect, "resource"), resource_ids, "#{path}.resource")
    |> then(
      &(&1 ++
          validate_numeric_expression(value(effect, "amount"), fact_context, "#{path}.amount"))
    )
    |> Kernel.++(validate_optional_target(effect, fact_context.relationships, path))
  end

  defp validate_effect(
         effect,
         "transfer_resource",
         resource_ids,
         _relationships,
         fact_context,
         path
       ) do
    []
    |> require_member(value(effect, "resource"), resource_ids, "#{path}.resource")
    |> require_in(value(effect, "from"), ~w(agent world target), "#{path}.from")
    |> require_in(value(effect, "to"), ~w(agent world target), "#{path}.to")
    |> then(
      &(&1 ++
          validate_numeric_expression(value(effect, "amount"), fact_context, "#{path}.amount"))
    )
    |> Kernel.++(validate_optional_target(effect, fact_context.relationships, path))
  end

  defp validate_effect(effect, op, _resources, relationship_ids, fact_context, path)
       when op in ~w(set_relationship adjust_relationship) do
    []
    |> require_member(value(effect, "relationship"), relationship_ids, "#{path}.relationship")
    |> then(&(&1 ++ validate_target(value(effect, "target"), relationship_ids, "#{path}.target")))
    |> then(
      &(&1 ++
          validate_numeric_expression(value(effect, "value"), fact_context, "#{path}.value"))
    )
  end

  defp validate_effect(_effect, _op, _resources, _relationships, _facts, _path), do: []

  defp declared_agent_effect_paths("set_agent", fact_context),
    do: Enum.map(fact_context.state, &"state.#{&1}")

  defp declared_agent_effect_paths("adjust_attribute", fact_context),
    do: Enum.map(fact_context.attributes, &"attributes.#{&1}")

  defp validate_target(%{"self" => true}, _relationship_ids, _path), do: []
  defp validate_target(%{"audience" => true}, _relationship_ids, _path), do: []
  defp validate_target("self", _relationship_ids, _path), do: []
  defp validate_target("audience", _relationship_ids, _path), do: []

  defp validate_target(%{"relationship_neighbors" => target}, relationship_ids, path)
       when is_map(target) do
    []
    |> require_member(
      value(target, "type"),
      relationship_ids,
      "#{path}.relationship_neighbors.type"
    )
    |> require_integer(value(target, "limit"), "#{path}.relationship_neighbors.limit", 1, 100)
  end

  defp validate_target(_target, _relationship_ids, path),
    do: [
      error(
        path,
        "unbounded_target",
        "must target self, audience, or a relationship neighborhood with a limit"
      )
    ]

  defp validate_optional_target(effect, relationship_ids, path) do
    if Map.has_key?(effect, "target") do
      validate_target(value(effect, "target"), relationship_ids, "#{path}.target")
    else
      []
    end
  end

  defp validate_emits(emits, path) do
    emits = list_value(emits)

    count_errors(emits, path, 0, 16) ++
      (emits
       |> Enum.with_index()
       |> Enum.flat_map(fn {emission, index} ->
         emission_path = "#{path}[#{index}]"

         []
         |> require_map(emission, emission_path)
         |> require_id(value(emission, "type"), "#{emission_path}.type")
         |> then(
           &(&1 ++
               validate_json_value(value(emission, "payload", %{}), "#{emission_path}.payload"))
         )
       end))
  end

  defp validate_weighted_candidates(candidates, action_ids, fact_context, policy_path)
       when is_map(candidates) do
    if map_size(candidates) in 1..@max_actions do
      candidates
      |> Enum.flat_map(fn {action_id, expression} ->
        require_member([], action_id, action_ids, "#{policy_path}.candidates.#{action_id}") ++
          validate_numeric_expression(
            expression,
            fact_context,
            "#{policy_path}.candidates.#{action_id}"
          )
      end)
    else
      [
        error(
          "#{policy_path}.candidates",
          "invalid_count",
          "must define between 1 and 64 candidates"
        )
      ]
    end
  end

  defp validate_weighted_candidates(_candidates, _actions, _facts, _path), do: []

  defp validate_policy_rules(rules, action_ids, fact_context, policy_path) do
    rules = list_value(rules)

    count_errors(rules, "#{policy_path}.rules", 1, 32) ++
      (rules
       |> Enum.with_index()
       |> Enum.flat_map(fn {rule, index} ->
         path = "#{policy_path}.rules[#{index}]"

         []
         |> require_map(rule, path)
         |> require_member(value(rule, "action"), action_ids, "#{path}.action")
         |> then(&(&1 ++ validate_condition(value(rule, "when"), fact_context, "#{path}.when")))
       end))
  end

  defp validate_optional_condition(nil, _fact_context, _path), do: []

  defp validate_optional_condition(condition, fact_context, path),
    do: validate_condition(condition, fact_context, path)

  defp validate_condition(condition, fact_context, path) do
    case condition_shape(condition, fact_context, path, 0, 0) do
      {_nodes, errors} -> errors
    end
  end

  defp condition_shape(_condition, _facts, path, depth, nodes)
       when depth > @max_expression_depth or nodes > @max_expression_nodes,
       do:
         {nodes,
          [error(path, "expression_too_complex", "expression exceeds its bounded depth or size")]}

  defp condition_shape(condition, facts, path, depth, nodes) when is_map(condition) do
    cond do
      Map.has_key?(condition, "all") or Map.has_key?(condition, "any") ->
        key = if Map.has_key?(condition, "all"), do: "all", else: "any"
        children = list(condition, key)

        if children == [] or length(children) > 32 do
          {nodes + 1,
           [error("#{path}.#{key}", "invalid_count", "must contain 1 to 32 conditions")]}
        else
          Enum.reduce(Enum.with_index(children), {nodes + 1, []}, fn {child, index},
                                                                     {count, errors} ->
            {next_count, next_errors} =
              condition_shape(child, facts, "#{path}.#{key}[#{index}]", depth + 1, count)

            {next_count, errors ++ next_errors}
          end)
        end

      Map.has_key?(condition, "not") ->
        condition_shape(value(condition, "not"), facts, "#{path}.not", depth + 1, nodes + 1)

      Map.has_key?(condition, "fact") ->
        fact = value(condition, "fact")
        op = value(condition, "op")

        errors =
          []
          |> validate_fact(fact, facts, "#{path}.fact")
          |> require_in(op, @condition_operators, "#{path}.op")

        errors =
          if op == "exists" or Map.has_key?(condition, "value"),
            do: errors,
            else: [error("#{path}.value", "required", "is required") | errors]

        {nodes + 1, errors}

      true ->
        {nodes + 1, [error(path, "unsupported_condition", "condition node is not supported")]}
    end
  end

  defp condition_shape(_condition, _facts, path, _depth, nodes),
    do: {nodes + 1, [error(path, "invalid_condition", "must be a condition object")]}

  defp validate_numeric_expression(expression, fact_context, path) do
    case numeric_shape(expression, fact_context, path, 0, 0) do
      {_nodes, errors} -> errors
    end
  end

  defp numeric_shape(_expression, _facts, path, depth, nodes)
       when depth > @max_expression_depth or nodes > @max_expression_nodes,
       do:
         {nodes,
          [error(path, "expression_too_complex", "expression exceeds its bounded depth or size")]}

  defp numeric_shape(expression, _facts, _path, _depth, nodes) when is_number(expression),
    do: {nodes + 1, []}

  defp numeric_shape(%{"fact" => fact}, facts, path, _depth, nodes),
    do: {nodes + 1, validate_fact([], fact, facts, "#{path}.fact")}

  defp numeric_shape(expression, facts, path, depth, nodes) when is_map(expression) do
    operators = Enum.filter(@numeric_operators, &Map.has_key?(expression, &1))

    case operators do
      [operator] ->
        operands = value(expression, operator) |> List.wrap()
        expected = if operator == "clamp", do: 3, else: 2

        if length(operands) != expected do
          {nodes + 1,
           [error("#{path}.#{operator}", "invalid_arity", "requires #{expected} operands")]}
        else
          Enum.reduce(Enum.with_index(operands), {nodes + 1, []}, fn {operand, index},
                                                                     {count, errors} ->
            {next_count, next_errors} =
              numeric_shape(operand, facts, "#{path}.#{operator}[#{index}]", depth + 1, count)

            {next_count, errors ++ next_errors}
          end)
        end

      _ ->
        {nodes + 1,
         [error(path, "unsupported_expression", "numeric expression node is not supported")]}
    end
  end

  defp numeric_shape(_expression, _facts, path, _depth, nodes),
    do: {nodes + 1, [error(path, "invalid_expression", "must be numeric or a typed expression")]}

  defp validate_metric(metric, "agent_fraction", _actions, _resources, _facts, path),
    do: validate_filter(value(metric, "filter"), "#{path}.filter")

  defp validate_metric(metric, "mean", _actions, _resources, facts, path),
    do: validate_fact([], value(metric, "fact"), facts, "#{path}.fact")

  defp validate_metric(metric, "action_count", actions, _resources, _facts, path),
    do: require_member([], value(metric, "action"), actions, "#{path}.action")

  defp validate_metric(metric, "resource_sum", _actions, resources, _facts, path),
    do: require_member([], value(metric, "resource"), resources, "#{path}.resource")

  defp validate_metric(metric, "relationship_count", _actions, _resources, facts, path),
    do:
      require_member(
        [],
        value(metric, "relationship"),
        facts.relationships,
        "#{path}.relationship"
      )

  defp validate_metric(metric, "world_value", _actions, _resources, facts, path),
    do: require_member([], value(metric, "key"), facts.world, "#{path}.key")

  defp validate_metric(_metric, _kind, _actions, _resources, _facts, _path), do: []

  defp validate_filter(filter, path) when is_map(filter) and map_size(filter) in 1..16 do
    filter
    |> Enum.flat_map(fn {key, nested} ->
      if is_binary(key) and String.starts_with?(key, "state.") and json_value?(nested, 0),
        do: [],
        else: [error("#{path}.#{key}", "invalid_filter", "must reference bounded agent state")]
    end)
  end

  defp validate_filter(_filter, path),
    do: [error(path, "invalid_filter", "must contain 1 to 16 state filters")]

  defp fact_context(script, population) do
    attributes =
      population
      |> list("agent_types")
      |> Enum.flat_map(
        &(&1
          |> list("attributes")
          |> Enum.map(fn attribute -> value(attribute, "key") end))
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    state =
      population
      |> list("archetypes")
      |> Enum.flat_map(&(&1 |> value("initial_state", %{}) |> Map.keys()))
      |> Kernel.++(["last_action"])
      |> Enum.uniq()

    %{
      world: script |> value("world", %{}) |> value("state", %{}) |> Map.keys(),
      attributes: attributes,
      state: state,
      resources: ids(list(script, "resources")),
      relationships: ids(list(script, "relationships"))
    }
  end

  defp validate_fact(errors, fact, facts, path) when is_binary(fact) do
    valid? =
      cond do
        String.starts_with?(fact, "world.") ->
          String.replace_prefix(fact, "world.", "") in facts.world

        String.starts_with?(fact, "agent.attributes.") ->
          String.replace_prefix(fact, "agent.attributes.", "") in facts.attributes

        String.starts_with?(fact, "agent.state.") ->
          String.replace_prefix(fact, "agent.state.", "") in facts.state

        String.starts_with?(fact, "agent.resources.") ->
          String.replace_prefix(fact, "agent.resources.", "") in facts.resources

        fact in ["decision.uncertainty", "event.relationship_weight"] ->
          true

        true ->
          false
      end

    if valid?,
      do: errors,
      else: [error(path, "unknown_fact", "does not reference a declared bounded fact") | errors]
  end

  defp validate_fact(errors, _fact, _facts, path),
    do: [error(path, "invalid_fact", "must be a bounded fact path") | errors]

  defp complexity_report(script, population) do
    population_size = value(population, "population_size", 0)
    rounds = get_in(script, ["clock", "count"]) || 0
    actions = length(list(script, "actions"))
    transitions = length(list(script, "transitions"))
    relationship_count = get_in(population, ["compile_summary", "relationship_count"]) || 0

    per_agent = max(actions, 1) + transitions
    estimated = population_size * rounds * per_agent + relationship_count * rounds

    %{
      "population_size" => population_size,
      "rounds" => rounds,
      "actions" => actions,
      "transitions" => transitions,
      "relationships" => relationship_count,
      "estimated_operations" => estimated,
      "limit" => @max_estimated_operations
    }
  end

  defp json_value?(_value, depth) when depth > 6, do: false
  defp json_value?(value, _depth) when is_binary(value), do: String.length(value) <= 1_000

  defp json_value?(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  defp json_value?(value, depth) when is_list(value) and length(value) <= 64,
    do: Enum.all?(value, &json_value?(&1, depth + 1))

  defp json_value?(value, depth) when is_map(value) and map_size(value) <= 64 do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.length(key) <= 120 and json_value?(nested, depth + 1)
    end)
  end

  defp json_value?(_value, _depth), do: false

  defp validate_json_value(value, path) do
    if json_value?(value, 0),
      do: [],
      else: [error(path, "invalid_value", "must be bounded JSON data")]
  end

  defp ids(items), do: type_ids_from_items(items)
  defp type_ids_from_script(script), do: script |> list("agent_types") |> type_ids_from_items()

  defp type_ids_from_items(items) do
    items
    |> Enum.map(&value(&1, "id"))
    |> Enum.reject(&is_nil/1)
  end

  defp duplicate_errors(values, path, label) do
    values
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {_value, 1} ->
        []

      {_value, _count} ->
        [error(path, "duplicate_identifier", "contains a duplicate #{label} identifier")]
    end)
  end

  defp count_errors(items, path, min, max) do
    count = length(items)

    if count >= min and count <= max,
      do: [],
      else: [error(path, "invalid_count", "must contain between #{min} and #{max} items")]
  end

  defp string_list_members(value, allowed, path, min, max) do
    list = list_value(value)

    []
    |> require_list(value, path)
    |> then(&(&1 ++ count_errors(list, path, min, max)))
    |> then(fn errors ->
      if Enum.all?(list, &(is_binary(&1) and &1 in allowed)),
        do: errors,
        else: [error(path, "unknown_reference", "contains an undeclared reference") | errors]
    end)
  end

  defp validate_string_list(value, path, max) do
    list = list_value(value)

    []
    |> require_list(value, path)
    |> then(&(&1 ++ count_errors(list, path, 0, max)))
    |> then(fn errors ->
      if Enum.all?(list, &(is_binary(&1) and String.length(&1) in 1..120)),
        do: errors,
        else: [error(path, "invalid_string_list", "contains an invalid value") | errors]
    end)
  end

  defp require_map(errors, value, _path) when is_map(value), do: errors

  defp require_map(errors, _value, path),
    do: [error(path, "invalid_type", "must be an object") | errors]

  defp require_list(errors, value, _path) when is_list(value), do: errors

  defp require_list(errors, _value, path),
    do: [error(path, "invalid_type", "must be a list") | errors]

  defp require_id(errors, value, path) when is_binary(value) do
    if valid_id?(value),
      do: errors,
      else: [error(path, "invalid_identifier", "must be a lowercase identifier") | errors]
  end

  defp require_id(errors, _value, path),
    do: [error(path, "invalid_identifier", "must be a lowercase identifier") | errors]

  defp valid_id?(value) when is_binary(value), do: Regex.match?(@id_pattern, value)
  defp valid_id?(_value), do: false

  defp require_string(errors, value, path, min, max) when is_binary(value) do
    length = String.length(String.trim(value))

    if length >= min and length <= max,
      do: errors,
      else: [error(path, "invalid_length", "has an invalid length") | errors]
  end

  defp require_string(errors, _value, path, _min, _max),
    do: [error(path, "invalid_type", "must be text") | errors]

  defp require_integer(errors, value, _path, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: errors

  defp require_integer(errors, _value, path, min, max),
    do: [error(path, "invalid_integer", "must be an integer from #{min} to #{max}") | errors]

  defp optional_integer(errors, nil, _path, _min, _max), do: errors

  defp optional_integer(errors, value, path, min, max),
    do: require_integer(errors, value, path, min, max)

  defp require_number(errors, value, _path, min, max)
       when is_number(value) and value >= min and value <= max,
       do: errors

  defp require_number(errors, _value, path, min, max),
    do: [error(path, "invalid_number", "must be a number from #{min} to #{max}") | errors]

  defp optional_number(errors, nil, _path, _min, _max), do: errors

  defp optional_number(errors, value, path, min, max),
    do: require_number(errors, value, path, min, max)

  defp optional_string(errors, nil, _path, _min, _max), do: errors

  defp optional_string(errors, value, path, min, max),
    do: require_string(errors, value, path, min, max)

  defp optional_boolean(errors, nil, _path), do: errors
  defp optional_boolean(errors, value, path), do: require_boolean(errors, value, path)

  defp optional_member(errors, nil, _members, _path), do: errors

  defp optional_member(errors, value, members, path),
    do: require_member(errors, value, members, path)

  defp require_boolean(errors, value, _path) when is_boolean(value), do: errors

  defp require_boolean(errors, _value, path),
    do: [error(path, "invalid_boolean", "must be true or false") | errors]

  defp require_equal(errors, value, expected, path) do
    if value == expected,
      do: errors,
      else: [error(path, "invalid_value", "must equal #{inspect(expected)}") | errors]
  end

  defp require_in(errors, value, allowed, path) do
    if value in allowed,
      do: errors,
      else: [error(path, "unsupported_value", "is not supported") | errors]
  end

  defp require_member(errors, value, allowed, path) do
    if value in allowed,
      do: errors,
      else: [error(path, "missing_reference", "does not reference a declared item") | errors]
  end

  defp list(map, key) when is_map(map), do: list_value(map[key])
  defp list(_map, _key), do: []
  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp value(map, key, default \\ nil)
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp value(_map, _key, default), do: default

  defp error(path, code, message), do: %{"path" => path, "code" => code, "message" => message}
end
