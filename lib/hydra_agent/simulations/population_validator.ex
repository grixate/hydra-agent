defmodule HydraAgent.Simulations.PopulationValidator do
  @moduledoc "Semantic validation for the bounded Population Model V1 contract."

  alias HydraAgent.Simulations.ContextPack

  @id_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @agent_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$/
  @attribute_types ~w(number integer categorical boolean)
  @distribution_kinds ~w(constant categorical uniform normal beta integer_range weighted_list)
  @relationship_kinds ~w(none random small_world hierarchical bipartite imported)
  @conditional_operators ~w(eq neq gt gte lt lte in)

  @sensitive_keys MapSet.new(~w(
    age biometric citizenship disability ethnicity gender genetic health
    medical nationality political_affiliation race religion sex
    sexual_orientation union_membership
  ))

  @max_agent_types 16
  @max_archetypes 64
  @max_attributes 32
  @max_conditions 64
  @max_relationship_rules 16
  @max_imported_agents 10_000
  @max_imported_relationships 100_000
  @max_generated_relationships 500_000

  def validate(contract, context_pack \\ nil)

  def validate(contract, context_pack) when is_map(contract) do
    types = list(contract["agent_types"])
    archetypes = list(contract["archetypes"])
    conditions = list(contract["conditional_distributions"])
    relationships = list(contract["relationship_rules"])
    imported_agents = list(contract["imported_agents"])
    imported_relationships = list(contract["imported_relationships"])

    errors =
      []
      |> require_equal(contract["schema_version"], 1, "$.schema_version", "must equal 1")
      |> require_string(contract["compiler_version"], "$.compiler_version", 3, 80)
      |> require_integer(contract["seed"], "$.seed", 0, 9_223_372_036_854_775_807)
      |> require_integer(contract["population_size"], "$.population_size", 10, 100_000)
      |> require_list(contract["agent_types"], "$.agent_types")
      |> require_list(contract["archetypes"], "$.archetypes")
      |> require_list(contract["conditional_distributions"], "$.conditional_distributions")
      |> require_list(contract["relationship_rules"], "$.relationship_rules")
      |> require_list(contract["imported_agents"], "$.imported_agents")
      |> require_list(contract["imported_relationships"], "$.imported_relationships")
      |> require_count(types, "$.agent_types", 1, @max_agent_types)
      |> require_count(archetypes, "$.archetypes", 1, @max_archetypes)
      |> require_count(conditions, "$.conditional_distributions", 0, @max_conditions)
      |> require_count(relationships, "$.relationship_rules", 0, @max_relationship_rules)
      |> require_count(imported_agents, "$.imported_agents", 0, @max_imported_agents)
      |> require_count(
        imported_relationships,
        "$.imported_relationships",
        0,
        @max_imported_relationships
      )
      |> require_map(contract["import_summary"], "$.import_summary")
      |> require_map(contract["compile_summary"], "$.compile_summary")
      |> require_map(contract["generation_metadata"], "$.generation_metadata")
      |> require_in(contract["status"], ~w(ready partial invalid), "$.status")
      |> validate_intended_use(contract)

    type_ids = ids(types)
    archetype_ids = ids(archetypes)

    errors =
      errors ++
        duplicate_errors(type_ids, "$.agent_types", "agent type") ++
        duplicate_errors(archetype_ids, "$.archetypes", "archetype") ++
        validate_types(types, context_pack) ++
        validate_type_weights(types) ++
        validate_archetypes(archetypes, types, context_pack) ++
        validate_archetype_weights(archetypes, type_ids) ++
        validate_conditions(conditions, types) ++
        validate_relationship_rules(relationships, types, contract["population_size"]) ++
        validate_representative_rules(contract["representative_rules"], archetype_ids) ++
        validate_imported_agents(imported_agents, types, archetypes, contract["population_size"]) ++
        validate_imported_relationships(imported_relationships, imported_agents)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.take(errors, 500)}
    end
  end

  def validate(_contract, _context_pack),
    do: {:error, [error("$", "invalid_contract", "must be an object")]}

  def sensitive_key?(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> then(&MapSet.member?(@sensitive_keys, &1))
  end

  def sensitive_key?(_key), do: false

  defp validate_types(types, context_pack) do
    types
    |> Enum.with_index()
    |> Enum.flat_map(fn {type, index} ->
      path = "$.agent_types[#{index}]"
      attributes = if is_map(type), do: list(type["attributes"]), else: []

      []
      |> require_map(type, path)
      |> require_id(value(type, "id"), "#{path}.id")
      |> require_string(value(type, "label"), "#{path}.label", 1, 120)
      |> require_string(value(type, "description"), "#{path}.description", 1, 500)
      |> require_number(value(type, "weight"), "#{path}.weight", 0.0, 1.0)
      |> require_count(attributes, "#{path}.attributes", 1, @max_attributes)
      |> then(
        &(&1 ++ duplicate_errors(ids(attributes, "key"), "#{path}.attributes", "attribute"))
      )
      |> then(&(&1 ++ validate_attributes(attributes, path)))
      |> then(&(&1 ++ validate_string_list(value(type, "resources"), "#{path}.resources", 24)))
      |> then(&(&1 ++ validate_string_list(value(type, "actions"), "#{path}.actions", 32)))
      |> then(
        &(&1 ++ validate_grounding(value(type, "grounding"), context_pack, "#{path}.grounding"))
      )
    end)
  end

  defp validate_attributes(attributes, type_path) do
    attributes
    |> Enum.with_index()
    |> Enum.flat_map(fn {attribute, index} ->
      path = "#{type_path}.attributes[#{index}]"
      type = value(attribute, "type")

      errors =
        []
        |> require_map(attribute, path)
        |> require_id(value(attribute, "key"), "#{path}.key")
        |> require_in(type, @attribute_types, "#{path}.type")

      errors =
        if type in ~w(number integer) do
          errors
          |> require_number(value(attribute, "min"), "#{path}.min", -1_000_000.0, 1_000_000.0)
          |> require_number(value(attribute, "max"), "#{path}.max", -1_000_000.0, 1_000_000.0)
          |> then(fn current ->
            min = value(attribute, "min")
            max = value(attribute, "max")

            if is_number(min) and is_number(max) and min > max,
              do: [error(path, "invalid_bounds", "minimum must not exceed maximum") | current],
              else: current
          end)
        else
          errors
        end

      errors ++ validate_sensitive_attribute(attribute, path)
    end)
  end

  defp validate_sensitive_attribute(attribute, path) do
    key = value(attribute, "key", "")
    sensitive = value(attribute, "sensitive") == true

    cond do
      sensitive_key?(key) and not sensitive ->
        [
          error(
            "#{path}.sensitive",
            "sensitive_attribute_not_declared",
            "a protected or sensitive attribute must be declared explicitly"
          )
        ]

      sensitive ->
        []
        |> require_equal(
          value(attribute, "source"),
          "observed",
          "#{path}.source",
          "must be observed"
        )
        |> require_string(value(attribute, "necessity"), "#{path}.necessity", 10, 500)
        |> require_string(value(attribute, "lawful_basis"), "#{path}.lawful_basis", 3, 200)
        |> require_equal(
          value(attribute, "aggregate_only"),
          true,
          "#{path}.aggregate_only",
          "must be true"
        )
        |> require_equal(
          value(attribute, "individual_exposure"),
          false,
          "#{path}.individual_exposure",
          "must be false"
        )

      true ->
        []
    end
  end

  defp validate_type_weights(types) do
    weights = Enum.map(types, &value(&1, "weight"))

    cond do
      not Enum.all?(weights, &(is_number(&1) and &1 >= 0)) ->
        []

      abs(Enum.sum(weights) - 1.0) > 0.000_001 ->
        [error("$.agent_types", "invalid_weights", "agent type weights must sum to 1")]

      true ->
        []
    end
  end

  defp validate_archetypes(archetypes, types, context_pack) do
    types_by_id = Map.new(types, &{value(&1, "id"), &1})

    archetypes
    |> Enum.with_index()
    |> Enum.flat_map(fn {archetype, index} ->
      path = "$.archetypes[#{index}]"
      type_id = value(archetype, "agent_type")
      type = types_by_id[type_id]
      attribute_keys = type |> value("attributes", []) |> ids("key") |> MapSet.new()
      distributions = value(archetype, "distributions", %{})

      []
      |> require_map(archetype, path)
      |> require_id(value(archetype, "id"), "#{path}.id")
      |> require_member(type_id, Map.keys(types_by_id), "#{path}.agent_type")
      |> require_number(value(archetype, "weight"), "#{path}.weight", 0.000_001, 1.0)
      |> require_string(value(archetype, "summary"), "#{path}.summary", 3, 500)
      |> require_map(distributions, "#{path}.distributions")
      |> then(
        &(&1 ++ validate_distributions(distributions, attribute_keys, "#{path}.distributions"))
      )
      |> then(&(&1 ++ validate_string_list(value(archetype, "goals"), "#{path}.goals", 16, 1)))
      |> then(
        &(&1 ++
            validate_string_list(value(archetype, "constraints"), "#{path}.constraints", 16))
      )
      |> then(&(&1 ++ validate_map(value(archetype, "initial_state"), "#{path}.initial_state")))
      |> then(
        &(&1 ++ validate_map(value(archetype, "initial_resources"), "#{path}.initial_resources"))
      )
      |> then(&(&1 ++ optional_id(value(archetype, "policy_id"), "#{path}.policy_id")))
      |> then(
        &(&1 ++ validate_string_list(value(archetype, "memory_seeds"), "#{path}.memory_seeds", 12))
      )
      |> then(
        &(&1 ++
            validate_grounding(value(archetype, "grounding"), context_pack, "#{path}.grounding"))
      )
    end)
  end

  defp validate_archetype_weights(archetypes, type_ids) do
    Enum.flat_map(type_ids, fn type_id ->
      weights =
        archetypes
        |> Enum.filter(&(value(&1, "agent_type") == type_id))
        |> Enum.map(&value(&1, "weight"))

      cond do
        weights == [] ->
          [error("$.archetypes", "missing_archetype", "agent type #{type_id} needs an archetype")]

        not Enum.all?(weights, &is_number/1) ->
          []

        abs(Enum.sum(weights) - 1.0) > 0.000_001 ->
          [
            error(
              "$.archetypes",
              "invalid_weights",
              "archetype weights for #{type_id} must sum to 1"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp validate_distributions(distributions, attribute_keys, path) when is_map(distributions) do
    Enum.flat_map(distributions, fn {key, distribution} ->
      distribution_path = "#{path}.#{key}"

      missing =
        if MapSet.member?(attribute_keys, key),
          do: [],
          else: [error(distribution_path, "unknown_attribute", "attribute is not declared")]

      missing ++ validate_distribution(distribution, distribution_path)
    end)
  end

  defp validate_distributions(_distributions, _attribute_keys, _path), do: []

  defp validate_distribution(distribution, path) when is_map(distribution) do
    kind = value(distribution, "kind")
    errors = require_in([], kind, @distribution_kinds, "#{path}.kind")

    errors ++
      case kind do
        "constant" ->
          if Map.has_key?(distribution, "value"),
            do: [],
            else: [error("#{path}.value", "required", "is required")]

        "categorical" ->
          validate_weighted_values(value(distribution, "values"), "#{path}.values")

        "weighted_list" ->
          validate_weighted_values(value(distribution, "values"), "#{path}.values")

        "uniform" ->
          validate_numeric_bounds(distribution, path, false)

        "normal" ->
          []
          |> require_number(
            value(distribution, "mean"),
            "#{path}.mean",
            -1_000_000.0,
            1_000_000.0
          )
          |> require_number(value(distribution, "sd"), "#{path}.sd", 0.000_001, 1_000_000.0)
          |> then(&(&1 ++ validate_numeric_bounds(distribution, path, false)))

        "beta" ->
          []
          |> require_number(value(distribution, "alpha"), "#{path}.alpha", 0.000_001, 10_000.0)
          |> require_number(value(distribution, "beta"), "#{path}.beta", 0.000_001, 10_000.0)
          |> then(&(&1 ++ validate_numeric_bounds(distribution, path, true)))

        "integer_range" ->
          []
          |> require_integer(value(distribution, "min"), "#{path}.min", -1_000_000, 1_000_000)
          |> require_integer(value(distribution, "max"), "#{path}.max", -1_000_000, 1_000_000)
          |> validate_order(value(distribution, "min"), value(distribution, "max"), path)

        _ ->
          []
      end
  end

  defp validate_distribution(_distribution, path),
    do: [error(path, "invalid_distribution", "must be an object")]

  defp validate_weighted_values(values, path) when is_map(values) and map_size(values) > 0 do
    if Enum.all?(values, fn {_value, weight} -> is_number(weight) and weight >= 0 end) and
         Enum.sum(Map.values(values)) > 0 do
      []
    else
      [error(path, "invalid_weights", "weights must be non-negative and include positive mass")]
    end
  end

  defp validate_weighted_values(values, path) when is_list(values) and values != [] do
    if Enum.all?(values, fn item ->
         is_map(item) and Map.has_key?(item, "value") and is_number(item["weight"]) and
           item["weight"] >= 0
       end) and Enum.sum(Enum.map(values, & &1["weight"])) > 0 do
      []
    else
      [
        error(
          path,
          "invalid_weights",
          "weighted items must contain value and non-negative weight"
        )
      ]
    end
  end

  defp validate_weighted_values(_values, path),
    do: [error(path, "invalid_weights", "must contain one or more weighted values")]

  defp validate_numeric_bounds(distribution, path, optional) do
    min = value(distribution, "min")
    max = value(distribution, "max")

    errors =
      if optional and is_nil(min) and is_nil(max) do
        []
      else
        []
        |> require_number(min, "#{path}.min", -1_000_000.0, 1_000_000.0)
        |> require_number(max, "#{path}.max", -1_000_000.0, 1_000_000.0)
      end

    validate_order(errors, min, max, path)
  end

  defp validate_order(errors, min, max, path) when is_number(min) and is_number(max) do
    if min <= max,
      do: errors,
      else: [error(path, "invalid_bounds", "minimum must not exceed maximum") | errors]
  end

  defp validate_order(errors, _min, _max, _path), do: errors

  defp validate_conditions(conditions, types) do
    attribute_keys =
      types
      |> Enum.flat_map(&(value(&1, "attributes", []) |> ids("key")))
      |> MapSet.new()

    conditions
    |> Enum.with_index()
    |> Enum.flat_map(fn {condition, index} ->
      path = "$.conditional_distributions[#{index}]"
      when_clause = value(condition, "when", %{})
      set = value(condition, "set", %{})

      []
      |> require_map(condition, path)
      |> require_map(when_clause, "#{path}.when")
      |> require_member(value(when_clause, "attribute"), attribute_keys, "#{path}.when.attribute")
      |> require_in(
        value(when_clause, "operator"),
        @conditional_operators,
        "#{path}.when.operator"
      )
      |> require_map(set, "#{path}.set")
      |> then(&(&1 ++ validate_distributions(set, attribute_keys, "#{path}.set")))
    end)
  end

  defp validate_relationship_rules(rules, types, population_size) do
    type_ids = ids(types)

    rules
    |> Enum.with_index()
    |> Enum.flat_map(fn {rule, index} ->
      path = "$.relationship_rules[#{index}]"
      kind = value(rule, "kind")
      settings = value(rule, "settings", %{})

      errors =
        []
        |> require_map(rule, path)
        |> require_in(kind, @relationship_kinds, "#{path}.kind")
        |> require_id(value(rule, "relationship_type"), "#{path}.relationship_type")
        |> require_boolean(value(rule, "directed"), "#{path}.directed")
        |> require_map(settings, "#{path}.settings")

      semantic_errors =
        case kind do
          "random" ->
            require_integer([], value(settings, "degree"), "#{path}.settings.degree", 1, 32)

          "small_world" ->
            []
            |> require_integer(value(settings, "degree"), "#{path}.settings.degree", 2, 32)
            |> require_number(
              value(settings, "rewire_probability"),
              "#{path}.settings.rewire_probability",
              0.0,
              1.0
            )

          "hierarchical" ->
            require_number(
              [],
              value(settings, "manager_ratio"),
              "#{path}.settings.manager_ratio",
              0.001,
              0.5
            )

          "bipartite" ->
            []
            |> require_member(
              value(settings, "left_type"),
              type_ids,
              "#{path}.settings.left_type"
            )
            |> require_member(
              value(settings, "right_type"),
              type_ids,
              "#{path}.settings.right_type"
            )
            |> require_integer(value(settings, "degree"), "#{path}.settings.degree", 1, 32)

          _ ->
            []
        end

      errors ++
        semantic_errors ++ relationship_capacity_errors(rule, types, population_size, path)
    end)
  end

  defp relationship_capacity_errors(rule, types, population_size, path)
       when is_map(rule) and is_integer(population_size) do
    settings = value(rule, "settings", %{})

    estimate =
      case value(rule, "kind") do
        "random" ->
          population_size * numeric_or_zero(value(settings, "degree"))

        "small_world" ->
          population_size * div(numeric_or_zero(value(settings, "degree")), 2)

        "hierarchical" ->
          population_size

        "bipartite" ->
          left_weight =
            types
            |> Enum.find(&(value(&1, "id") == value(settings, "left_type")))
            |> value("weight", 0.0)

          ceil(population_size * left_weight) * numeric_or_zero(value(settings, "degree"))

        _ ->
          0
      end

    if estimate > @max_generated_relationships do
      [
        error(
          path,
          "relationship_limit_exceeded",
          "would exceed the #{@max_generated_relationships} generated-relationship limit"
        )
      ]
    else
      []
    end
  end

  defp relationship_capacity_errors(_rule, _types, _population_size, _path), do: []

  defp numeric_or_zero(value) when is_integer(value) and value > 0, do: value
  defp numeric_or_zero(_value), do: 0

  defp validate_representative_rules(rules, archetype_ids) when is_map(rules) do
    per_archetype = value(rules, "per_archetype")
    high_influence = value(rules, "high_influence")
    outliers = value(rules, "outliers")

    []
    |> require_integer(per_archetype, "$.representative_rules.per_archetype", 1, 3)
    |> require_integer(high_influence, "$.representative_rules.high_influence", 0, 12)
    |> require_integer(outliers, "$.representative_rules.outliers", 0, 12)
    |> then(fn errors ->
      if archetype_ids == [],
        do: [
          error("$.representative_rules", "missing_archetypes", "requires archetypes") | errors
        ],
        else: errors
    end)
  end

  defp validate_representative_rules(_rules, _archetype_ids),
    do: [error("$.representative_rules", "invalid_rules", "must be an object")]

  defp validate_imported_agents(agents, types, archetypes, population_size) do
    type_ids = types |> ids() |> MapSet.new()
    archetypes_by_id = Map.new(archetypes, &{value(&1, "id"), &1})

    errors =
      if is_integer(population_size) and length(agents) > population_size,
        do: [error("$.imported_agents", "too_many_agents", "cannot exceed population size")],
        else: []

    errors ++
      duplicate_errors(ids(agents), "$.imported_agents", "agent") ++
      (agents
       |> Enum.with_index()
       |> Enum.flat_map(fn {agent, index} ->
         path = "$.imported_agents[#{index}]"
         type_id = value(agent, "type")
         archetype_id = value(agent, "archetype")

         []
         |> require_map(agent, path)
         |> require_pattern(value(agent, "id"), @agent_id_pattern, "#{path}.id")
         |> require_member(type_id, type_ids, "#{path}.type")
         |> then(fn current ->
           cond do
             is_nil(archetype_id) ->
               current

             is_nil(archetypes_by_id[archetype_id]) ->
               [error("#{path}.archetype", "unknown_archetype", "is not declared") | current]

             value(archetypes_by_id[archetype_id], "agent_type") != type_id ->
               [
                 error(
                   "#{path}.archetype",
                   "archetype_type_mismatch",
                   "does not belong to the imported agent type"
                 )
                 | current
               ]

             true ->
               current
           end
         end)
         |> then(&(&1 ++ validate_map(value(agent, "attributes"), "#{path}.attributes")))
         |> then(&(&1 ++ validate_map(value(agent, "resources"), "#{path}.resources")))
         |> then(&(&1 ++ validate_map(value(agent, "initial_state"), "#{path}.initial_state")))
         |> then(
           &(&1 ++
               validate_imported_attributes(
                 value(agent, "attributes", %{}),
                 Enum.find(types, fn type -> value(type, "id") == type_id end),
                 "#{path}.attributes"
               ))
         )
       end))
  end

  defp validate_imported_attributes(attributes, type, path)
       when is_map(attributes) and is_map(type) do
    definitions = Map.new(value(type, "attributes", []), &{value(&1, "key"), &1})

    Enum.flat_map(attributes, fn {key, imported_value} ->
      case definitions[key] do
        nil ->
          [error("#{path}.#{key}", "unknown_attribute", "is not declared for the agent type")]

        definition ->
          validate_imported_attribute_value(imported_value, definition, "#{path}.#{key}")
      end
    end)
  end

  defp validate_imported_attributes(_attributes, _type, _path), do: []

  defp validate_imported_attribute_value(value, %{"type" => "number"} = definition, path) do
    if is_number(value) and value >= definition["min"] and value <= definition["max"],
      do: [],
      else: [
        error(path, "invalid_attribute_value", "must be a number inside the declared bounds")
      ]
  end

  defp validate_imported_attribute_value(value, %{"type" => "integer"} = definition, path) do
    if is_integer(value) and value >= definition["min"] and value <= definition["max"],
      do: [],
      else: [
        error(path, "invalid_attribute_value", "must be an integer inside the declared bounds")
      ]
  end

  defp validate_imported_attribute_value(value, %{"type" => "boolean"}, path) do
    if is_boolean(value),
      do: [],
      else: [error(path, "invalid_attribute_value", "must be true or false")]
  end

  defp validate_imported_attribute_value(value, %{"type" => "categorical"}, path) do
    if is_binary(value) and byte_size(value) <= 500,
      do: [],
      else: [error(path, "invalid_attribute_value", "must be a bounded category")]
  end

  defp validate_imported_attribute_value(_value, _definition, path),
    do: [error(path, "invalid_attribute_value", "does not match the attribute contract")]

  defp validate_imported_relationships(relationships, agents) do
    agent_ids = agents |> ids() |> MapSet.new()

    relationships
    |> Enum.with_index()
    |> Enum.flat_map(fn {relationship, index} ->
      path = "$.imported_relationships[#{index}]"
      source = value(relationship, "source")
      target = value(relationship, "target")

      []
      |> require_map(relationship, path)
      |> require_pattern(value(relationship, "id"), @agent_id_pattern, "#{path}.id")
      |> require_member(source, agent_ids, "#{path}.source")
      |> require_member(target, agent_ids, "#{path}.target")
      |> require_id(value(relationship, "type"), "#{path}.type")
      |> require_number(value(relationship, "weight"), "#{path}.weight", 0.0, 1.0)
      |> require_boolean(value(relationship, "directed"), "#{path}.directed")
      |> then(fn errors ->
        if source == target,
          do: [error(path, "self_relationship", "source and target must differ") | errors],
          else: errors
      end)
    end)
    |> Kernel.++(duplicate_errors(ids(relationships), "$.imported_relationships", "relationship"))
  end

  defp validate_grounding(values, nil, path), do: validate_string_list(values, path, 32)

  defp validate_grounding(values, %ContextPack{} = context_pack, path) do
    allowed =
      (context_pack.sources ++ context_pack.claims ++ context_pack.assumptions)
      |> ids()
      |> MapSet.new()

    validate_string_list(values, path, 32, 1) ++
      (values
       |> list()
       |> Enum.with_index()
       |> Enum.flat_map(fn {reference, index} ->
         if MapSet.member?(allowed, reference),
           do: [],
           else: [
             error("#{path}[#{index}]", "unknown_grounding", "does not exist in the Context Pack")
           ]
       end))
  end

  defp validate_intended_use(errors, contract) do
    intended_use = contract |> value("generation_metadata", %{}) |> value("intended_use")

    if intended_use == "individual_consequential_recommendation" do
      [
        error(
          "$.generation_metadata.intended_use",
          "prohibited_use",
          "individual consequential recommendations are prohibited"
        )
        | errors
      ]
    else
      errors
    end
  end

  defp validate_map(value, _path) when is_map(value), do: []
  defp validate_map(_value, path), do: [error(path, "invalid_object", "must be an object")]

  defp validate_string_list(values, path, max, min \\ 0)

  defp validate_string_list(values, path, max, min) when is_list(values) do
    count_errors = require_count([], values, path, min, max)

    count_errors ++
      (values
       |> Enum.with_index()
       |> Enum.flat_map(fn {value, index} ->
         require_string([], value, "#{path}[#{index}]", 1, 500)
       end))
  end

  defp validate_string_list(_values, path, _max, _min),
    do: [error(path, "invalid_list", "must be a list")]

  defp optional_id(nil, _path), do: []
  defp optional_id(value, path), do: require_id([], value, path)

  defp duplicate_errors(values, path, label) do
    values
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {value, count} when count > 1 ->
        [error(path, "duplicate_id", "#{label} ID #{inspect(value)} is duplicated")]

      _entry ->
        []
    end)
  end

  defp ids(values, key \\ "id"), do: Enum.map(values, &value(&1, key))

  defp require_map(errors, value, _path) when is_map(value), do: errors

  defp require_map(errors, _value, path),
    do: [error(path, "invalid_object", "must be an object") | errors]

  defp require_list(errors, value, _path) when is_list(value), do: errors

  defp require_list(errors, _value, path),
    do: [error(path, "invalid_array", "must be an array") | errors]

  defp require_id(errors, value, path), do: require_pattern(errors, value, @id_pattern, path)

  defp require_pattern(errors, value, pattern, path) when is_binary(value) do
    if Regex.match?(pattern, value),
      do: errors,
      else: [error(path, "invalid_identifier", "has an invalid identifier") | errors]
  end

  defp require_pattern(errors, _value, _pattern, path),
    do: [error(path, "invalid_identifier", "has an invalid identifier") | errors]

  defp require_string(errors, value, _path, min, max)
       when is_binary(value) and byte_size(value) >= min and byte_size(value) <= max,
       do: errors

  defp require_string(errors, _value, path, _min, _max),
    do: [error(path, "invalid_string", "has an invalid length") | errors]

  defp require_integer(errors, value, _path, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: errors

  defp require_integer(errors, _value, path, _min, _max),
    do: [error(path, "invalid_integer", "is outside the supported range") | errors]

  defp require_number(errors, value, _path, min, max)
       when is_number(value) and value >= min and value <= max,
       do: errors

  defp require_number(errors, _value, path, _min, _max),
    do: [error(path, "invalid_number", "is outside the supported range") | errors]

  defp require_boolean(errors, value, _path) when is_boolean(value), do: errors

  defp require_boolean(errors, _value, path),
    do: [error(path, "invalid_boolean", "must be true or false") | errors]

  defp require_equal(errors, value, expected, _path, _message) when value == expected, do: errors

  defp require_equal(errors, _value, _expected, path, message),
    do: [error(path, "invalid_value", message) | errors]

  defp require_in(errors, value, allowed, path) do
    if Enum.member?(allowed, value),
      do: errors,
      else: [error(path, "invalid_value", "is not supported") | errors]
  end

  defp require_member(errors, value, allowed, path) do
    if Enum.member?(allowed, value),
      do: errors,
      else: [error(path, "unknown_reference", "is not declared") | errors]
  end

  defp require_count(errors, values, _path, min, max)
       when is_list(values) and length(values) >= min and length(values) <= max,
       do: errors

  defp require_count(errors, _values, path, _min, _max),
    do: [error(path, "invalid_count", "has an unsupported number of items") | errors]

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp value(map, key, default \\ nil)
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp value(_map, _key, default), do: default

  defp error(path, code, message), do: %{"path" => path, "code" => code, "message" => message}
end
