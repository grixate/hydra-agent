defmodule HydraAgent.Simulations.PopulationImporter do
  @moduledoc "Bounded CSV/JSON import with row-level errors and no raw-value diagnostics."

  alias HydraAgent.Simulations.{ContentHash, PopulationValidator}

  @max_bytes 5_000_000
  @max_agent_rows 10_000
  @max_relationship_rows 100_000
  @max_columns 100
  @max_cell_bytes 10_000
  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$/

  def import(filename, content, params \\ %{})

  def import(filename, content, params)
      when is_binary(filename) and is_binary(content) and is_map(params) do
    cond do
      byte_size(content) > @max_bytes ->
        {:error, :population_import_too_large}

      not String.valid?(content) ->
        {:error, :population_import_invalid_utf8}

      extension(filename) == ".csv" ->
        import_csv(filename, content, params)

      extension(filename) == ".json" ->
        import_json(filename, content, params)

      true ->
        {:error, :population_import_invalid_file}
    end
  end

  def import(_filename, _content, _params), do: {:error, :population_import_invalid_file}

  def limits do
    %{
      max_bytes: @max_bytes,
      max_agent_rows: @max_agent_rows,
      max_relationship_rows: @max_relationship_rows,
      max_columns: @max_columns
    }
  end

  defp import_csv(filename, content, params) do
    with {:ok, rows} <- parse_csv(content),
         [headers | data_rows] <- rows,
         :ok <- validate_headers(headers) do
      kind = normalize_kind(params["kind"] || params[:kind])
      headers = Enum.map(headers, &String.trim/1)

      with :ok <- validate_row_limit(kind, data_rows) do
        case kind do
          "relationships" -> import_csv_relationships(filename, headers, data_rows, params)
          _agents -> import_csv_agents(filename, headers, data_rows, params)
        end
      end
    else
      [] -> {:error, :population_import_empty}
      {:error, _reason} = error -> error
    end
  end

  defp import_csv_agents(filename, headers, rows, params) do
    mapping = agent_mapping(params, headers)

    {agents, errors} =
      rows
      |> Enum.with_index(2)
      |> Enum.reduce({[], []}, fn {cells, row_number}, {agents, errors} ->
        row = row_map(headers, cells)

        case normalize_agent(row, mapping, row_number) do
          {:ok, agent, _profile} ->
            {[{agent, row_number} | agents], errors}

          {:error, row_errors} ->
            {agents, row_errors ++ errors}
        end
      end)

    {agents, duplicate_errors} = agents |> Enum.reverse() |> deduplicate_tagged_agents()
    errors = Enum.reverse(errors) ++ duplicate_errors
    profiles = profiles_from_agents(agents)

    {:ok,
     %{
       kind: :agents,
       agents: agents,
       relationships: [],
       type_profiles: profiles,
       population_model: nil,
       summary:
         summary(
           filename,
           "csv",
           "agents",
           agents,
           [],
           errors,
           content_fingerprint(filename, rows)
         )
     }}
  end

  defp import_csv_relationships(filename, headers, rows, params) do
    mapping = relationship_mapping(params, headers)

    {relationships, errors} =
      rows
      |> Enum.with_index(2)
      |> Enum.reduce({[], []}, fn {cells, row_number}, {relationships, errors} ->
        row = row_map(headers, cells)

        case normalize_relationship(row, mapping, row_number) do
          {:ok, relationship} -> {[relationship | relationships], errors}
          {:error, row_errors} -> {relationships, row_errors ++ errors}
        end
      end)

    relationships = relationships |> Enum.reverse() |> Enum.uniq_by(& &1["id"])
    errors = Enum.reverse(errors)

    {:ok,
     %{
       kind: :relationships,
       agents: [],
       relationships: relationships,
       type_profiles: %{},
       population_model: nil,
       summary:
         summary(
           filename,
           "csv",
           "relationships",
           [],
           relationships,
           errors,
           content_fingerprint(filename, rows)
         )
     }}
  end

  defp import_json(filename, content, params) do
    with {:ok, decoded} <- Jason.decode(content) do
      cond do
        is_map(decoded) and decoded["hydra_population_model"] == 1 ->
          import_json_model(filename, decoded, content)

        normalize_kind(params["kind"] || params[:kind]) == "relationships" ->
          rows = if is_map(decoded), do: decoded["relationships"], else: decoded
          import_json_relationships(filename, rows, content)

        true ->
          rows = if is_map(decoded), do: decoded["agents"], else: decoded
          import_json_agents(filename, rows, content)
      end
    else
      _ -> {:error, :population_import_invalid_json}
    end
  end

  defp import_json_model(filename, decoded, content) do
    contract =
      decoded
      |> Map.delete("hydra_population_model")
      |> Map.put_new("schema_version", 1)
      |> Map.put_new("compiler_version", "hydra-population/v1")
      |> Map.put_new("conditional_distributions", [])
      |> Map.put_new("relationship_rules", [])
      |> Map.put_new("representative_rules", %{
        "per_archetype" => 1,
        "high_influence" => 2,
        "outliers" => 2
      })
      |> Map.put_new("imported_agents", [])
      |> Map.put_new("imported_relationships", [])
      |> Map.put_new("import_summary", %{})
      |> Map.put_new("compile_summary", %{})
      |> Map.put_new("generation_metadata", %{"intended_use" => "aggregate_simulation"})
      |> Map.put_new("status", "ready")
      |> pseudonymize_contract_imports()

    case PopulationValidator.validate(contract) do
      :ok ->
        {:ok,
         %{
           kind: :population_model,
           agents: [],
           relationships: [],
           type_profiles: %{},
           population_model: contract,
           summary: %{
             "filename" => Path.basename(filename),
             "format" => "json",
             "kind" => "population_model",
             "valid_count" => 1,
             "error_count" => 0,
             "errors" => [],
             "content_hash" => ContentHash.digest(content)
           }
         }}

      {:error, errors} ->
        {:ok,
         %{
           kind: :population_model,
           agents: [],
           relationships: [],
           type_profiles: %{},
           population_model: nil,
           summary: %{
             "filename" => Path.basename(filename),
             "format" => "json",
             "kind" => "population_model",
             "valid_count" => 0,
             "error_count" => length(errors),
             "errors" => Enum.take(errors, 200),
             "content_hash" => ContentHash.digest(content)
           }
         }}
    end
  end

  defp import_json_agents(filename, rows, content) when is_list(rows) do
    if length(rows) > @max_agent_rows do
      {:error, :population_import_too_many_rows}
    else
      do_import_json_agents(filename, rows, content)
    end
  end

  defp import_json_agents(_filename, _rows, _content),
    do: {:error, :population_import_invalid_json_shape}

  defp do_import_json_agents(filename, rows, content) do
    mapping = %{
      id: "id",
      type: "type",
      archetype: "archetype",
      attributes: :nested,
      resources: :nested,
      state: :nested
    }

    {agents, errors} =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {row, row_number}, {agents, errors} ->
        case normalize_agent(row, mapping, row_number) do
          {:ok, agent, _profile} ->
            {[{agent, row_number} | agents], errors}

          {:error, row_errors} ->
            {agents, row_errors ++ errors}
        end
      end)

    {agents, duplicate_errors} = agents |> Enum.reverse() |> deduplicate_tagged_agents()
    errors = Enum.reverse(errors)
    errors = errors ++ duplicate_errors
    profiles = profiles_from_agents(agents)

    {:ok,
     %{
       kind: :agents,
       agents: agents,
       relationships: [],
       type_profiles: profiles,
       population_model: nil,
       summary:
         summary(filename, "json", "agents", agents, [], errors, ContentHash.digest(content))
     }}
  end

  defp import_json_relationships(filename, rows, content) when is_list(rows) do
    if length(rows) > @max_relationship_rows do
      {:error, :population_import_too_many_rows}
    else
      do_import_json_relationships(filename, rows, content)
    end
  end

  defp import_json_relationships(_filename, _rows, _content),
    do: {:error, :population_import_invalid_json_shape}

  defp do_import_json_relationships(filename, rows, content) do
    mapping = %{
      source: "source",
      target: "target",
      type: "type",
      weight: "weight",
      directed: "directed"
    }

    {relationships, errors} =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {row, row_number}, {relationships, errors} ->
        case normalize_relationship(row, mapping, row_number) do
          {:ok, relationship} -> {[relationship | relationships], errors}
          {:error, row_errors} -> {relationships, row_errors ++ errors}
        end
      end)

    relationships = relationships |> Enum.reverse() |> Enum.uniq_by(& &1["id"])
    errors = Enum.reverse(errors)

    {:ok,
     %{
       kind: :relationships,
       agents: [],
       relationships: relationships,
       type_profiles: %{},
       population_model: nil,
       summary:
         summary(
           filename,
           "json",
           "relationships",
           [],
           relationships,
           errors,
           ContentHash.digest(content)
         )
     }}
  end

  defp normalize_agent(row, mapping, row_number) when is_map(row) do
    id = field(row, mapping.id)
    type = field(row, mapping.type) |> safe_id()
    archetype = field(row, mapping.archetype) |> optional_safe_id()

    attributes = nested_or_columns(row, mapping.attributes, "attributes")
    resources = nested_or_columns(row, mapping.resources, "resources")
    initial_state = nested_or_columns(row, mapping.state, "initial_state")

    errors =
      []
      |> validate_external_id(id, row_number, "id")
      |> validate_safe_id(type, row_number, "type")
      |> validate_map(attributes, row_number, "attributes")
      |> validate_map(resources, row_number, "resources")
      |> validate_map(initial_state, row_number, "initial_state")
      |> reject_sensitive_keys(attributes, row_number)

    if errors == [] do
      attributes = scalar_map(attributes)
      resources = scalar_map(resources)
      initial_state = scalar_map(initial_state)

      agent = %{
        "id" => pseudonymous_agent_id(id),
        "type" => type,
        "archetype" => archetype,
        "attributes" => attributes,
        "resources" => resources,
        "initial_state" => initial_state
      }

      {:ok, agent, profile(type, attributes, resources)}
    else
      {:error, errors}
    end
  end

  defp normalize_agent(_row, _mapping, row_number),
    do: {:error, [row_error(row_number, "row", "invalid_row", "must be an object")]}

  defp normalize_relationship(row, mapping, row_number) when is_map(row) do
    source = field(row, mapping.source)
    target = field(row, mapping.target)
    type = field(row, mapping.type) |> safe_id()
    weight = field(row, mapping.weight) |> parse_number(1.0)
    directed = field(row, mapping.directed) |> parse_boolean(false)

    errors =
      []
      |> validate_external_id(source, row_number, "source")
      |> validate_external_id(target, row_number, "target")
      |> validate_safe_id(type, row_number, "type")
      |> then(fn current ->
        if is_number(weight) and weight >= 0 and weight <= 1,
          do: current,
          else: [
            row_error(row_number, "weight", "invalid_weight", "must be between 0 and 1") | current
          ]
      end)
      |> then(fn current ->
        if source == target,
          do: [
            row_error(row_number, "target", "self_relationship", "must differ from source")
            | current
          ],
          else: current
      end)
      |> then(fn current ->
        if is_boolean(directed),
          do: current,
          else: [
            row_error(row_number, "directed", "invalid_boolean", "must be true or false")
            | current
          ]
      end)

    if errors == [] do
      source = pseudonymous_agent_id(source)
      target = pseudonymous_agent_id(target)

      {:ok,
       %{
         "id" => stable_id("relationship", "#{type}:#{source}:#{target}:#{directed}"),
         "source" => source,
         "target" => target,
         "type" => type,
         "weight" => weight,
         "directed" => directed,
         "state" => %{}
       }}
    else
      {:error, errors}
    end
  end

  defp normalize_relationship(_row, _mapping, row_number),
    do: {:error, [row_error(row_number, "row", "invalid_row", "must be an object")]}

  defp agent_mapping(params, headers) do
    %{
      id: column(params, "id_column", "id", headers),
      type: column(params, "type_column", "type", headers),
      archetype: column(params, "archetype_column", "archetype", headers, true),
      attributes:
        mapping_columns(
          params["attribute_columns"] || params[:attribute_columns],
          headers,
          "attribute_"
        ),
      resources:
        mapping_columns(
          params["resource_columns"] || params[:resource_columns],
          headers,
          "resource_"
        ),
      state: mapping_columns(params["state_columns"] || params[:state_columns], headers, "state_")
    }
  end

  defp relationship_mapping(params, headers) do
    %{
      source: column(params, "source_column", "source", headers),
      target: column(params, "target_column", "target", headers),
      type: column(params, "relationship_type_column", "type", headers),
      weight: column(params, "weight_column", "weight", headers, true),
      directed: column(params, "directed_column", "directed", headers, true)
    }
  end

  defp column(params, key, fallback, headers, optional \\ false) do
    requested = params[key] || params[String.to_atom(key)] || fallback
    requested = requested |> to_string() |> String.trim()

    cond do
      requested in headers -> requested
      fallback in headers -> fallback
      optional -> nil
      true -> requested
    end
  end

  defp mapping_columns(nil, headers, prefix) do
    headers
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&{&1, safe_id(String.replace_prefix(&1, prefix, ""))})
  end

  defp mapping_columns(value, headers, _prefix) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn token ->
      case String.split(token, ":", parts: 2) do
        [source, target] ->
          if source in headers, do: [{source, safe_id(target)}], else: []

        [source] ->
          if source in headers, do: [{source, safe_id(source)}], else: []

        _ ->
          []
      end
    end)
    |> Enum.reject(fn {_source, target} -> target == "" end)
  end

  defp nested_or_columns(row, :nested, key), do: row[key] || %{}
  defp nested_or_columns(_row, nil, _key), do: %{}

  defp nested_or_columns(row, columns, _key) when is_list(columns) do
    Map.new(columns, fn {source, target} -> {target, row[source]} end)
  end

  defp field(_row, nil), do: nil
  defp field(row, key), do: row[key]

  defp row_map(headers, cells) do
    padded = cells ++ List.duplicate("", max(length(headers) - length(cells), 0))
    headers |> Enum.zip(padded) |> Map.new()
  end

  defp validate_headers(headers) do
    cond do
      headers == [] -> {:error, :population_import_empty}
      length(headers) > @max_columns -> {:error, :population_import_too_many_columns}
      Enum.any?(headers, &(byte_size(&1) > 120)) -> {:error, :population_import_invalid_headers}
      Enum.uniq(headers) != headers -> {:error, :population_import_duplicate_headers}
      true -> :ok
    end
  end

  defp validate_external_id(errors, value, row, field) when is_binary(value) do
    if Regex.match?(@id_pattern, value),
      do: errors,
      else: [row_error(row, field, "invalid_identifier", "is missing or invalid") | errors]
  end

  defp validate_external_id(errors, _value, row, field),
    do: [row_error(row, field, "invalid_identifier", "is missing or invalid") | errors]

  defp validate_safe_id(errors, value, _row, _field) when is_binary(value) and value != "",
    do: errors

  defp validate_safe_id(errors, _value, row, field),
    do: [row_error(row, field, "invalid_identifier", "is missing or invalid") | errors]

  defp validate_map(errors, value, _row, _field) when is_map(value), do: errors

  defp validate_map(errors, _value, row, field),
    do: [row_error(row, field, "invalid_object", "must be an object") | errors]

  defp reject_sensitive_keys(errors, attributes, row) when is_map(attributes) do
    Enum.reduce(attributes, errors, fn {key, _value}, current ->
      if PopulationValidator.sensitive_key?(to_string(key)) do
        [
          row_error(
            row,
            "attributes.#{key}",
            "sensitive_attribute_requires_model_metadata",
            "requires explicit necessity and lawful-basis metadata in a Population Model import"
          )
          | current
        ]
      else
        current
      end
    end)
  end

  defp reject_sensitive_keys(errors, _attributes, _row), do: errors

  defp scalar_map(values) do
    values
    |> Enum.map(fn {key, value} -> {safe_id(key), parse_scalar(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_scalar(value) when is_boolean(value) or is_number(value) or is_nil(value), do: value

  defp parse_scalar(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.downcase(value) in ~w(true false) -> String.downcase(value) == "true"
      match?({_, ""}, Integer.parse(value)) -> value |> Integer.parse() |> elem(0)
      match?({_, ""}, Float.parse(value)) -> value |> Float.parse() |> elem(0)
      true -> String.slice(value, 0, 500)
    end
  end

  defp parse_scalar(value), do: value |> to_string() |> String.slice(0, 500)

  defp parse_number(nil, fallback), do: fallback
  defp parse_number("", fallback), do: fallback
  defp parse_number(value, _fallback) when is_number(value), do: value / 1

  defp parse_number(value, _fallback) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> :invalid
    end
  end

  defp parse_number(_value, fallback), do: fallback

  defp parse_boolean(nil, fallback), do: fallback
  defp parse_boolean("", fallback), do: fallback
  defp parse_boolean(value, _fallback) when is_boolean(value), do: value

  defp parse_boolean(value, _fallback) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ~w(true 1 yes y) -> true
      value when value in ~w(false 0 no n) -> false
      _ -> :invalid
    end
  end

  defp parse_boolean(_value, fallback), do: fallback

  defp profile(type, attributes, resources) do
    %{
      "id" => type,
      "attributes" => infer_attribute_definitions(attributes),
      "resources" => Map.keys(resources) |> Enum.sort()
    }
  end

  defp merge_profile(profiles, profile) do
    Map.update(profiles, profile["id"], profile, fn existing ->
      %{
        existing
        | "attributes" =>
            merge_attribute_definitions(existing["attributes"], profile["attributes"]),
          "resources" => Enum.sort(Enum.uniq(existing["resources"] ++ profile["resources"]))
      }
    end)
  end

  defp merge_attribute_definitions(previous, incoming) do
    (previous ++ incoming)
    |> Enum.group_by(& &1["key"])
    |> Enum.map(fn {_key, definitions} ->
      Enum.reduce(definitions, fn definition, merged ->
        cond do
          merged["type"] == definition["type"] and merged["type"] in ~w(number integer) ->
            merged
            |> Map.put("min", min(merged["min"], definition["min"]))
            |> Map.put("max", max(merged["max"], definition["max"]))

          merged["type"] == definition["type"] ->
            merged

          true ->
            %{"key" => merged["key"], "type" => "categorical", "sensitive" => false}
        end
      end)
    end)
    |> Enum.sort_by(& &1["key"])
  end

  defp infer_attribute_definitions(attributes) do
    attributes
    |> Enum.map(fn {key, value} ->
      case value do
        value when is_integer(value) ->
          %{
            "key" => key,
            "type" => "integer",
            "min" => min(value, 0),
            "max" => max(value, 1),
            "sensitive" => false
          }

        value when is_float(value) ->
          %{
            "key" => key,
            "type" => "number",
            "min" => min(value, 0.0),
            "max" => max(value, 1.0),
            "sensitive" => false
          }

        value when is_boolean(value) ->
          %{"key" => key, "type" => "boolean", "sensitive" => false}

        _ ->
          %{"key" => key, "type" => "categorical", "sensitive" => false}
      end
    end)
  end

  defp deduplicate_tagged_agents(tagged_agents) do
    {agents, errors, _seen} =
      Enum.reduce(tagged_agents, {[], [], MapSet.new()}, fn {agent, row},
                                                            {agents, errors, seen} ->
        if MapSet.member?(seen, agent["id"]) do
          error = row_error(row, "id", "duplicate_identifier", "duplicates an earlier agent ID")
          {agents, [error | errors], seen}
        else
          {[agent | agents], errors, MapSet.put(seen, agent["id"])}
        end
      end)

    {Enum.reverse(agents), Enum.reverse(errors)}
  end

  defp profiles_from_agents(agents) do
    Enum.reduce(agents, %{}, fn agent, profiles ->
      merge_profile(
        profiles,
        profile(agent["type"], agent["attributes"], agent["resources"])
      )
    end)
  end

  defp summary(filename, format, kind, agents, relationships, errors, hash) do
    %{
      "filename" => Path.basename(filename),
      "format" => format,
      "kind" => kind,
      "valid_count" => length(agents) + length(relationships),
      "error_count" => length(errors),
      "errors" => Enum.take(errors, 200),
      "content_hash" => hash
    }
  end

  defp content_fingerprint(filename, rows),
    do: ContentHash.digest(%{"filename" => Path.basename(filename), "rows" => rows})

  defp normalize_kind(value) when value in ["relationships", :relationships], do: "relationships"
  defp normalize_kind(_value), do: "agents"

  defp validate_row_limit("relationships", rows) do
    if length(rows) <= @max_relationship_rows,
      do: :ok,
      else: {:error, :population_import_too_many_rows}
  end

  defp validate_row_limit(_kind, rows) do
    if length(rows) <= @max_agent_rows,
      do: :ok,
      else: {:error, :population_import_too_many_rows}
  end

  defp extension(filename), do: filename |> Path.extname() |> String.downcase()

  defp safe_id(nil), do: ""

  defp safe_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      <<first::utf8, _rest::binary>> = id when first in ?a..?z -> String.slice(id, 0, 64)
      "" -> ""
      id -> String.slice("type_#{id}", 0, 64)
    end
  end

  defp optional_safe_id(nil), do: nil
  defp optional_safe_id(""), do: nil
  defp optional_safe_id(value), do: safe_id(value)

  defp stable_id(prefix, value) do
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    "#{prefix}-#{String.slice(digest, 0, 20)}"
  end

  defp pseudonymous_agent_id(value),
    do: stable_id("source", value |> to_string() |> String.trim())

  defp pseudonymize_contract_imports(contract) do
    source_agents = contract["imported_agents"]
    agents = if is_list(source_agents), do: source_agents, else: []

    id_map =
      agents
      |> Enum.flat_map(fn
        %{"id" => id} when is_binary(id) -> [{id, pseudonymous_agent_id(id)}]
        _agent -> []
      end)
      |> Map.new()

    agents =
      Enum.map(agents, fn
        agent when is_map(agent) ->
          case id_map[agent["id"]] do
            nil -> agent
            pseudonym -> Map.put(agent, "id", pseudonym)
          end

        agent ->
          agent
      end)

    source_relationships = contract["imported_relationships"]

    relationships =
      if is_list(source_relationships) do
        Enum.map(source_relationships, fn
          relationship when is_map(relationship) ->
            relationship
            |> Map.update("source", nil, &pseudonymize_reference(&1, id_map))
            |> Map.update("target", nil, &pseudonymize_reference(&1, id_map))

          relationship ->
            relationship
        end)
      else
        source_relationships
      end

    contract
    |> Map.put("imported_agents", if(is_list(source_agents), do: agents, else: source_agents))
    |> Map.put("imported_relationships", relationships)
  end

  defp pseudonymize_reference(value, id_map) when is_binary(value),
    do: Map.get(id_map, value, pseudonymous_agent_id(value))

  defp pseudonymize_reference(value, _id_map), do: value

  defp row_error(row, field, code, message) do
    %{"row" => row, "field" => field, "code" => code, "message" => message}
  end

  defp parse_csv(content) do
    case parse_csv_bytes(content, [], [], [], false) do
      {:ok, rows} ->
        rows = Enum.reject(rows, fn row -> Enum.all?(row, &(&1 == "")) end)

        if Enum.any?(rows, fn row ->
             length(row) > @max_columns or Enum.any?(row, &(byte_size(&1) > @max_cell_bytes))
           end) do
          {:error, :population_import_invalid_cells}
        else
          {:ok, rows}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_csv_bytes(<<>>, field, row, rows, false) do
    row = Enum.reverse([finish_field(field) | row])
    {:ok, Enum.reverse([row | rows])}
  end

  defp parse_csv_bytes(<<>>, _field, _row, _rows, true),
    do: {:error, :population_import_unclosed_quote}

  defp parse_csv_bytes(<<?", ?", rest::binary>>, field, row, rows, true),
    do: parse_csv_bytes(rest, [?" | field], row, rows, true)

  defp parse_csv_bytes(<<?", rest::binary>>, field, row, rows, true),
    do: parse_csv_bytes(rest, field, row, rows, false)

  defp parse_csv_bytes(<<byte, rest::binary>>, field, row, rows, true),
    do: parse_csv_bytes(rest, [byte | field], row, rows, true)

  defp parse_csv_bytes(<<?", rest::binary>>, [], row, rows, false),
    do: parse_csv_bytes(rest, [], row, rows, true)

  defp parse_csv_bytes(<<?,, rest::binary>>, field, row, rows, false),
    do: parse_csv_bytes(rest, [], [finish_field(field) | row], rows, false)

  defp parse_csv_bytes(<<?\r, ?\n, rest::binary>>, field, row, rows, false) do
    completed = Enum.reverse([finish_field(field) | row])
    parse_csv_bytes(rest, [], [], [completed | rows], false)
  end

  defp parse_csv_bytes(<<?\n, rest::binary>>, field, row, rows, false) do
    completed = Enum.reverse([finish_field(field) | row])
    parse_csv_bytes(rest, [], [], [completed | rows], false)
  end

  defp parse_csv_bytes(<<?\r, rest::binary>>, field, row, rows, false) do
    completed = Enum.reverse([finish_field(field) | row])
    parse_csv_bytes(rest, [], [], [completed | rows], false)
  end

  defp parse_csv_bytes(<<?", _rest::binary>>, _field, _row, _rows, false),
    do: {:error, :population_import_invalid_quote}

  defp parse_csv_bytes(<<byte, rest::binary>>, field, row, rows, false),
    do: parse_csv_bytes(rest, [byte | field], row, rows, false)

  defp finish_field(bytes), do: bytes |> Enum.reverse() |> :erlang.list_to_binary()
end
