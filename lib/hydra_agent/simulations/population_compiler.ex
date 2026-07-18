defmodule HydraAgent.Simulations.PopulationCompiler do
  @moduledoc "Deterministically materializes bounded agent state from Population Model V1."

  alias HydraAgent.Simulations.{ContentHash, PopulationValidator}

  @max_relationships 1_000_000
  @uint64_denominator 18_446_744_073_709_551_616

  def compile(contract, opts \\ [])

  def compile(contract, opts) when is_map(contract) do
    size = Keyword.get(opts, :population_size, contract["population_size"])
    seed = Keyword.get(opts, :seed, contract["seed"])
    contract = contract |> Map.put("population_size", size) |> Map.put("seed", seed)

    with :ok <- PopulationValidator.validate(contract),
         true <- is_integer(size) and size in 10..100_000,
         true <- is_integer(seed) and seed >= 0 do
      do_compile(contract)
    else
      false ->
        {:error,
         [
           %{
             "path" => "$",
             "code" => "invalid_compile_options",
             "message" => "size or seed is invalid"
           }
         ]}

      {:error, _errors} = error ->
        error
    end
  end

  def compile(_contract, _opts),
    do:
      {:error, [%{"path" => "$", "code" => "invalid_contract", "message" => "must be an object"}]}

  defp do_compile(contract) do
    seed = contract["seed"]
    size = contract["population_size"]
    types = contract["agent_types"]
    archetypes = contract["archetypes"]
    imported = contract["imported_agents"] || []
    generated_size = size - length(imported)

    type_counts = apportion(generated_size, types, & &1["weight"])

    archetype_counts =
      Enum.reduce(types, %{}, fn type, counts ->
        type_archetypes = Enum.filter(archetypes, &(&1["agent_type"] == type["id"]))
        allocated = apportion(type_counts[type["id"]] || 0, type_archetypes, & &1["weight"])
        Map.merge(counts, allocated)
      end)

    generated_agents =
      archetypes
      |> Enum.flat_map(fn archetype ->
        type = Enum.find(types, &(&1["id"] == archetype["agent_type"]))
        count = archetype_counts[archetype["id"]] || 0

        if count > 0 do
          Enum.map(0..(count - 1), fn index ->
            instantiate_agent(type, archetype, index, seed, contract["conditional_distributions"])
          end)
        else
          []
        end
      end)

    {imported_agents, imported_id_map} = instantiate_imported(imported, types, archetypes, seed)
    agents = generated_agents ++ imported_agents

    imported_relationships =
      normalize_imported_relationships(contract["imported_relationships"] || [], imported_id_map)

    relationships =
      generate_relationships(
        agents,
        contract["relationship_rules"] || [],
        imported_relationships,
        seed
      )

    representatives =
      select_representatives(
        agents,
        types,
        archetypes,
        relationships,
        contract["representative_rules"] || %{},
        seed
      )

    combined_type_counts = frequencies(agents, "type")
    combined_archetype_counts = frequencies(agents, "archetype")

    summary = %{
      "population_size" => length(agents),
      "generated_agent_count" => length(generated_agents),
      "imported_agent_count" => length(imported_agents),
      "type_counts" => combined_type_counts,
      "archetype_counts" => combined_archetype_counts,
      "relationship_count" => length(relationships),
      "representative_count" => length(representatives),
      "representatives" => representatives,
      "agent_set_hash" => agent_set_hash(agents),
      "relationship_hash" => ContentHash.digest(relationships),
      "compiler_version" => contract["compiler_version"],
      "seed" => seed
    }

    {:ok,
     %{
       agents: agents,
       relationships: relationships,
       representatives: representatives,
       summary: summary
     }}
  end

  defp instantiate_agent(type, archetype, index, seed, conditions) do
    agent_id = stable_id("agent", "#{seed}:#{type["id"]}:#{archetype["id"]}:#{index}")

    attributes =
      type["attributes"]
      |> Enum.reduce(%{}, fn definition, values ->
        key = definition["key"]
        distribution = archetype["distributions"][key] || default_distribution(definition)
        sampled = sample(distribution, seed, "#{agent_id}:attribute:#{key}")
        Map.put(values, key, normalize_attribute(sampled, definition))
      end)
      |> apply_conditions(conditions, type, seed, agent_id)

    resources =
      type["resources"]
      |> Enum.reduce(%{}, fn resource, values ->
        specification = get_in(archetype, ["initial_resources", resource])
        value = sample_value(specification, seed, "#{agent_id}:resource:#{resource}", 0.5)
        Map.put(values, resource, normalize_number(value))
      end)

    %{
      "id" => agent_id,
      "type" => type["id"],
      "archetype" => archetype["id"],
      "attributes" => attributes,
      "resources" => resources,
      "state" => archetype["initial_state"],
      "goals" => archetype["goals"],
      "constraints" => archetype["constraints"],
      "policy_id" => archetype["policy_id"],
      "memory_seeds" => archetype["memory_seeds"],
      "imported" => false
    }
  end

  defp instantiate_imported(imported, types, archetypes, seed) do
    types_by_id = Map.new(types, &{&1["id"], &1})
    archetypes_by_id = Map.new(archetypes, &{&1["id"], &1})

    imported
    |> Enum.map_reduce(%{}, fn source, id_map ->
      type = types_by_id[source["type"]]
      archetype = imported_archetype(source, type, archetypes, archetypes_by_id)
      runtime_id = stable_id("imported", "#{seed}:#{source["id"]}")

      attributes = normalize_imported_attributes(source["attributes"] || %{}, type)
      resources = source["resources"] || %{}

      agent = %{
        "id" => runtime_id,
        "type" => type["id"],
        "archetype" => archetype["id"],
        "attributes" => attributes,
        "resources" => resources,
        "state" => source["initial_state"] || %{},
        "goals" => archetype["goals"],
        "constraints" => archetype["constraints"],
        "policy_id" => archetype["policy_id"],
        "memory_seeds" => [],
        "imported" => true,
        "source_id_hash" => ContentHash.digest(source["id"])
      }

      {agent, Map.put(id_map, source["id"], runtime_id)}
    end)
  end

  defp imported_archetype(source, type, archetypes, archetypes_by_id) do
    archetypes_by_id[source["archetype"]] ||
      Enum.find(archetypes, &(&1["agent_type"] == type["id"]))
  end

  defp normalize_imported_attributes(attributes, type) do
    definitions = Map.new(type["attributes"], &{&1["key"], &1})

    Enum.reduce(definitions, %{}, fn {key, definition}, normalized ->
      if Map.has_key?(attributes, key) do
        Map.put(normalized, key, normalize_attribute(attributes[key], definition))
      else
        normalized
      end
    end)
  end

  defp normalize_imported_relationships(relationships, id_map) do
    Enum.flat_map(relationships, fn relationship ->
      source = id_map[relationship["source"]]
      target = id_map[relationship["target"]]

      if source && target do
        [
          relationship(
            source,
            target,
            relationship["type"],
            relationship["directed"],
            relationship["weight"],
            relationship["state"] || %{}
          )
        ]
      else
        []
      end
    end)
  end

  defp apply_conditions(attributes, conditions, type, seed, agent_id) do
    definitions = Map.new(type["attributes"], &{&1["key"], &1})

    Enum.reduce(conditions || [], attributes, fn condition, current ->
      when_clause = condition["when"]

      if condition_matches?(current[when_clause["attribute"]], when_clause) do
        Enum.reduce(condition["set"], current, fn {key, distribution}, updated ->
          case definitions[key] do
            nil ->
              updated

            definition ->
              value = sample(distribution, seed, "#{agent_id}:conditional:#{key}")
              Map.put(updated, key, normalize_attribute(value, definition))
          end
        end)
      else
        current
      end
    end)
  end

  defp condition_matches?(current, %{"operator" => "eq", "value" => value}), do: current == value
  defp condition_matches?(current, %{"operator" => "neq", "value" => value}), do: current != value

  defp condition_matches?(current, %{"operator" => "gt", "value" => value})
       when is_number(current) and is_number(value), do: current > value

  defp condition_matches?(current, %{"operator" => "gte", "value" => value})
       when is_number(current) and is_number(value), do: current >= value

  defp condition_matches?(current, %{"operator" => "lt", "value" => value})
       when is_number(current) and is_number(value), do: current < value

  defp condition_matches?(current, %{"operator" => "lte", "value" => value})
       when is_number(current) and is_number(value), do: current <= value

  defp condition_matches?(current, %{"operator" => "in", "value" => values}) when is_list(values),
    do: current in values

  defp condition_matches?(_current, _condition), do: false

  defp default_distribution(%{"type" => "number", "min" => min, "max" => max}),
    do: %{"kind" => "constant", "value" => (min + max) / 2}

  defp default_distribution(%{"type" => "integer", "min" => min, "max" => max}),
    do: %{"kind" => "constant", "value" => div(min + max, 2)}

  defp default_distribution(%{"type" => "boolean"}),
    do: %{"kind" => "constant", "value" => false}

  defp default_distribution(_definition), do: %{"kind" => "constant", "value" => nil}

  defp sample_value(specification, seed, path, _fallback) when is_map(specification),
    do: sample(specification, seed, path)

  defp sample_value(nil, _seed, _path, fallback), do: fallback
  defp sample_value(value, _seed, _path, _fallback), do: value

  defp sample(%{"kind" => "constant", "value" => value}, _seed, _path), do: value

  defp sample(%{"kind" => kind, "values" => values}, seed, path)
       when kind in ["categorical", "weighted_list"] do
    weighted_choice(values, unit(seed, path, 0))
  end

  defp sample(%{"kind" => "uniform", "min" => min, "max" => max}, seed, path),
    do: min + unit(seed, path, 0) * (max - min)

  defp sample(%{"kind" => "normal"} = distribution, seed, path) do
    mean = distribution["mean"]
    sd = distribution["sd"]
    u1 = max(unit(seed, path, 0), 1.0e-15)
    u2 = unit(seed, path, 1)
    value = mean + sd * :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
    clamp(value, distribution["min"], distribution["max"])
  end

  defp sample(%{"kind" => "beta"} = distribution, seed, path) do
    alpha = distribution["alpha"]
    beta = distribution["beta"]
    x = gamma(alpha, seed, "#{path}:alpha")
    y = gamma(beta, seed, "#{path}:beta")
    normalized = if x + y == 0, do: 0.5, else: x / (x + y)
    min = distribution["min"] || 0.0
    max = distribution["max"] || 1.0
    min + normalized * (max - min)
  end

  defp sample(%{"kind" => "integer_range", "min" => min, "max" => max}, seed, path),
    do: (min + floor(unit(seed, path, 0) * (max - min + 1))) |> min(max)

  defp sample(_distribution, _seed, _path), do: nil

  defp gamma(shape, seed, path) when shape < 1.0 do
    gamma(shape + 1.0, seed, "#{path}:raised") *
      :math.pow(max(unit(seed, path, 99), 1.0e-15), 1.0 / shape)
  end

  defp gamma(shape, seed, path) do
    d = shape - 1.0 / 3.0
    c = 1.0 / :math.sqrt(9.0 * d)
    gamma_attempt(d, c, seed, path, 0)
  end

  defp gamma_attempt(d, _c, _seed, _path, attempt) when attempt >= 64, do: d

  defp gamma_attempt(d, c, seed, path, attempt) do
    u1 = max(unit(seed, path, attempt * 3), 1.0e-15)
    u2 = unit(seed, path, attempt * 3 + 1)
    x = :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi() * u2)
    v_root = 1.0 + c * x

    if v_root <= 0 do
      gamma_attempt(d, c, seed, path, attempt + 1)
    else
      v = v_root * v_root * v_root
      u = max(unit(seed, path, attempt * 3 + 2), 1.0e-15)

      if u < 1.0 - 0.0331 * x * x * x * x or
           :math.log(u) < 0.5 * x * x + d * (1.0 - v + :math.log(v)) do
        d * v
      else
        gamma_attempt(d, c, seed, path, attempt + 1)
      end
    end
  end

  defp weighted_choice(values, position) when is_map(values) do
    values
    |> Enum.map(fn {value, weight} -> {value, weight} end)
    |> Enum.sort_by(&to_string(elem(&1, 0)))
    |> choose_weighted(position)
  end

  defp weighted_choice(values, position) when is_list(values) do
    values
    |> Enum.map(&{&1["value"], &1["weight"]})
    |> choose_weighted(position)
  end

  defp choose_weighted(items, position) do
    total = Enum.sum_by(items, &elem(&1, 1))
    target = position * total

    items
    |> Enum.reduce_while({nil, 0.0}, fn {value, weight}, {_selected, cumulative} ->
      next = cumulative + weight
      if target <= next, do: {:halt, {value, next}}, else: {:cont, {value, next}}
    end)
    |> elem(0)
    |> case do
      nil -> items |> List.last() |> elem(0)
      value -> value
    end
  end

  defp normalize_attribute(value, %{"type" => "number"} = definition) when is_number(value) do
    value |> clamp(definition["min"], definition["max"]) |> normalize_number()
  end

  defp normalize_attribute(value, %{"type" => "integer"} = definition) when is_number(value) do
    value |> round() |> clamp(definition["min"], definition["max"])
  end

  defp normalize_attribute(value, %{"type" => "boolean"}) when is_boolean(value), do: value

  defp normalize_attribute(value, %{"type" => "categorical"}) when is_binary(value),
    do: String.slice(value, 0, 120)

  defp normalize_attribute(_value, %{"type" => "number", "min" => min}), do: min
  defp normalize_attribute(_value, %{"type" => "integer", "min" => min}), do: min
  defp normalize_attribute(_value, %{"type" => "boolean"}), do: false
  defp normalize_attribute(value, _definition), do: value

  defp generate_relationships(agents, rules, imported, seed) do
    generated =
      Enum.flat_map(rules, fn rule ->
        case rule["kind"] do
          "none" -> []
          "random" -> random_relationships(agents, rule, seed)
          "small_world" -> small_world_relationships(agents, rule, seed)
          "hierarchical" -> hierarchical_relationships(agents, rule)
          "bipartite" -> bipartite_relationships(agents, rule, seed)
          "imported" -> imported
          _ -> []
        end
      end)

    (imported ++ generated)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
    |> Enum.take(@max_relationships)
  end

  defp random_relationships(agents, rule, seed) do
    count = length(agents)
    degree = get_in(rule, ["settings", "degree"])
    agent_tuple = List.to_tuple(agents)

    if count < 2 do
      []
    else
      agents
      |> Enum.with_index()
      |> Enum.flat_map(fn {agent, index} ->
        Enum.map(1..degree, fn slot ->
          target_index = floor(unit(seed, "random:#{agent["id"]}:#{slot}", 0) * count)

          target_index =
            if target_index == index, do: rem(target_index + 1, count), else: target_index

          target = elem(agent_tuple, target_index)

          relationship(
            agent["id"],
            target["id"],
            rule["relationship_type"],
            rule["directed"],
            1.0
          )
        end)
      end)
      |> unique_relationships(rule["directed"])
    end
  end

  defp small_world_relationships(agents, rule, seed) do
    count = length(agents)
    requested_degree = get_in(rule, ["settings", "degree"])
    degree = requested_degree |> min(max(count - 1, 0)) |> then(&(div(&1, 2) * 2))
    probability = get_in(rule, ["settings", "rewire_probability"])
    agent_tuple = List.to_tuple(agents)

    if count < 3 or degree < 2 do
      []
    else
      agents
      |> Enum.with_index()
      |> Enum.flat_map(fn {agent, index} ->
        Enum.map(1..div(degree, 2), fn offset ->
          ring_target = rem(index + offset, count)
          rewire? = unit(seed, "small-world:#{agent["id"]}:#{offset}", 0) < probability

          target_index =
            if rewire? do
              candidate = floor(unit(seed, "small-world:#{agent["id"]}:#{offset}", 1) * count)
              if candidate == index, do: ring_target, else: candidate
            else
              ring_target
            end

          target = elem(agent_tuple, target_index)

          relationship(
            agent["id"],
            target["id"],
            rule["relationship_type"],
            rule["directed"],
            1.0
          )
        end)
      end)
      |> unique_relationships(rule["directed"])
    end
  end

  defp hierarchical_relationships(agents, rule) do
    count = length(agents)
    ratio = get_in(rule, ["settings", "manager_ratio"])
    manager_count = count |> Kernel.*(ratio) |> round() |> max(1) |> min(max(count - 1, 1))
    {managers, members} = Enum.split(agents, manager_count)

    if members == [] do
      []
    else
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} ->
        manager = Enum.at(managers, rem(index, manager_count))
        relationship(manager["id"], member["id"], rule["relationship_type"], true, 1.0)
      end)
    end
  end

  defp bipartite_relationships(agents, rule, seed) do
    left = Enum.filter(agents, &(&1["type"] == get_in(rule, ["settings", "left_type"])))
    right = Enum.filter(agents, &(&1["type"] == get_in(rule, ["settings", "right_type"])))
    right_tuple = List.to_tuple(right)
    degree = get_in(rule, ["settings", "degree"])

    if left == [] or right == [] do
      []
    else
      left
      |> Enum.flat_map(fn source ->
        Enum.map(1..min(degree, length(right)), fn slot ->
          index = floor(unit(seed, "bipartite:#{source["id"]}:#{slot}", 0) * length(right))
          target = elem(right_tuple, index)

          relationship(
            source["id"],
            target["id"],
            rule["relationship_type"],
            rule["directed"],
            1.0
          )
        end)
      end)
      |> unique_relationships(rule["directed"])
    end
  end

  defp unique_relationships(relationships, directed) do
    relationships
    |> Enum.reduce(%{}, fn relationship, unique ->
      source = relationship["source"]
      target = relationship["target"]
      key = if directed or source < target, do: {source, target}, else: {target, source}
      Map.put_new(unique, key, relationship)
    end)
    |> Map.values()
  end

  defp relationship(source, target, type, directed, weight, state \\ %{}) do
    {stable_source, stable_target} =
      if directed or source < target, do: {source, target}, else: {target, source}

    %{
      "id" => stable_id("relationship", "#{type}:#{stable_source}:#{stable_target}:#{directed}"),
      "type" => type,
      "source" => stable_source,
      "target" => stable_target,
      "weight" => normalize_number(weight),
      "directed" => directed,
      "state" => state
    }
  end

  defp select_representatives(agents, types, archetypes, relationships, rules, seed) do
    per_archetype = rules["per_archetype"] || 1
    high_influence = rules["high_influence"] || 0
    outliers = rules["outliers"] || 0

    archetype_representatives =
      Enum.flat_map(archetypes, fn archetype ->
        agents
        |> Enum.filter(&(&1["archetype"] == archetype["id"]))
        |> Enum.sort_by(&ContentHash.digest("#{seed}:representative:#{&1["id"]}"))
        |> Enum.take(per_archetype)
      end)

    influential =
      agents
      |> Enum.sort_by(fn agent ->
        {-numeric(get_in(agent, ["attributes", "influence"])), agent["id"]}
      end)
      |> Enum.take(high_influence)

    selected_outliers =
      agents
      |> Enum.sort_by(fn agent -> {-outlier_score(agent), agent["id"]} end)
      |> Enum.take(outliers)

    type_by_id = Map.new(types, &{&1["id"], &1})
    archetype_by_id = Map.new(archetypes, &{&1["id"], &1})

    (archetype_representatives ++ influential ++ selected_outliers)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(32)
    |> Enum.map(fn agent ->
      type = type_by_id[agent["type"]]
      archetype = archetype_by_id[agent["archetype"]]

      sensitive_keys =
        type["attributes"]
        |> Enum.filter(&(&1["sensitive"] == true))
        |> Enum.map(& &1["key"])

      %{
        "agent_id" => agent["id"],
        "agent_type" => agent["type"],
        "agent_type_label" => type["label"],
        "archetype_id" => agent["archetype"],
        "archetype_summary" => archetype["summary"],
        "attributes" => Map.drop(agent["attributes"], sensitive_keys),
        "resources" => agent["resources"],
        "state" => agent["state"],
        "goals" => agent["goals"],
        "constraints" => agent["constraints"],
        "important_relationships" => important_relationships(agent["id"], relationships),
        "grounding" => archetype["grounding"],
        "prose_generated" => false,
        "generated_lazily" => true
      }
    end)
  end

  defp important_relationships(agent_id, relationships) do
    relationships
    |> Enum.filter(&(&1["source"] == agent_id or &1["target"] == agent_id))
    |> Enum.take(8)
    |> Enum.map(&Map.take(&1, ["id", "type", "source", "target", "weight", "directed"]))
  end

  defp outlier_score(agent) do
    agent["attributes"]
    |> Map.values()
    |> Enum.filter(&is_number/1)
    |> Enum.sum_by(&abs(&1 - 0.5))
  end

  defp apportion(0, items, _weight), do: Map.new(items, &{&1["id"], 0})

  defp apportion(total, items, weight) do
    total_weight = Enum.sum_by(items, weight)

    rows =
      Enum.map(items, fn item ->
        exact = total * weight.(item) / total_weight
        base = floor(exact)
        %{id: item["id"], count: base, remainder: exact - base}
      end)

    remaining = total - Enum.sum_by(rows, & &1.count)

    bonuses =
      rows
      |> Enum.sort_by(&{-&1.remainder, &1.id})
      |> Enum.take(remaining)
      |> MapSet.new(& &1.id)

    Map.new(rows, fn row ->
      {row.id, row.count + if(MapSet.member?(bonuses, row.id), do: 1, else: 0)}
    end)
  end

  defp frequencies(items, key) do
    items
    |> Enum.map(& &1[key])
    |> Enum.frequencies()
    |> Map.new(fn {id, count} -> {id, count} end)
  end

  defp agent_set_hash(agents) do
    agents
    |> Enum.map(
      &Map.take(&1, ["id", "type", "archetype", "attributes", "resources", "state", "policy_id"])
    )
    |> ContentHash.digest()
  end

  defp unit(seed, path, counter) do
    <<value::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, "#{seed}:#{path}:#{counter}")

    value / @uint64_denominator
  end

  defp stable_id(prefix, value) do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    "#{prefix}-#{String.slice(digest, 0, 20)}"
  end

  defp clamp(value, nil, nil), do: value
  defp clamp(value, min, nil) when is_number(min), do: max(value, min)
  defp clamp(value, nil, max) when is_number(max), do: min(value, max)

  defp clamp(value, min, max) when is_number(min) and is_number(max),
    do: value |> max(min) |> min(max)

  defp clamp(value, _min, _max), do: value

  defp numeric(value) when is_number(value), do: value / 1
  defp numeric(_value), do: 0.0

  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: Float.round(value, 6)
  defp normalize_number(value), do: value
end
