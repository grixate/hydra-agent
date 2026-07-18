defmodule HydraAgent.Simulations.BlueprintManifest do
  @moduledoc "Strict parser and semantic validator for `blueprint.yaml`."

  @modules ~w(research agents simulation report)
  @expected_paths %{
    "research" => {"instructions/research.md", "schemas/context-pack.schema.json"},
    "agents" => {"instructions/agents.md", "schemas/population-model.schema.json"},
    "simulation" => {"instructions/simulation.md", "schemas/simulation-script.schema.json"},
    "report" => {"instructions/report.md", "schemas/report.schema.json"}
  }
  @variable_types ~w(string integer number boolean enum array)
  @supported_capabilities %{
    "build" => ~w(structured_generation long_context),
    "simulation" => ~w(optional_fast_reasoning structured_generation),
    "report" => ~w(structured_generation long_context)
  }
  @top_key_order ~w(hydra_blueprint id name version description modules variables capabilities defaults compatibility files)

  def modules, do: @modules
  def supported_capabilities, do: @supported_capabilities

  def parse(yaml) when is_binary(yaml) do
    cond do
      not String.valid?(yaml) ->
        error(:invalid_encoding, "blueprint.yaml must be valid UTF-8")

      String.contains?(yaml, <<0>>) ->
        error(:invalid_yaml, "blueprint.yaml contains a null byte")

      yaml_alias_or_tag?(yaml) ->
        error(:unsafe_yaml, "YAML aliases, anchors, and explicit tags are not supported")

      true ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, manifest} when is_map(manifest) -> {:ok, stringify_keys(manifest)}
          {:ok, _other} -> error(:invalid_manifest, "blueprint.yaml must contain a map")
          {:error, reason} -> error(:invalid_yaml, "blueprint.yaml could not be parsed", reason)
        end
    end
  rescue
    exception ->
      error(:invalid_yaml, "blueprint.yaml could not be parsed", Exception.message(exception))
  catch
    kind, reason -> error(:invalid_yaml, "blueprint.yaml could not be parsed", {kind, reason})
  end

  def validate(manifest, available_files) when is_map(manifest) do
    errors =
      []
      |> require_equal(manifest, "hydra_blueprint", 1)
      |> validate_id(manifest)
      |> validate_semver(manifest)
      |> validate_localized(manifest, "name", 2, 100)
      |> validate_localized(manifest, "description", 8, 500)
      |> validate_modules(manifest, available_files)
      |> validate_variables(manifest)
      |> validate_capabilities(manifest)
      |> validate_defaults(manifest)
      |> validate_compatibility(manifest)

    warnings = compatibility_warnings(manifest)

    if errors == [], do: {:ok, warnings}, else: {:error, errors, warnings}
  end

  def encode(manifest) when is_map(manifest) do
    manifest
    |> stringify_keys()
    |> encode_map(0, @top_key_order)
    |> IO.iodata_to_binary()
  end

  defp require_equal(errors, manifest, key, expected) do
    if manifest[key] == expected,
      do: errors,
      else: add_error(errors, key, :invalid_value, "must equal #{inspect(expected)}")
  end

  defp validate_id(errors, manifest) do
    case manifest["id"] do
      id when is_binary(id) ->
        if Regex.match?(~r/^[a-z0-9][a-z0-9-]{1,99}$/, id),
          do: errors,
          else: add_error(errors, "id", :invalid_id, "must be a lowercase kebab-case identifier")

      _ ->
        add_error(errors, "id", :required, "is required")
    end
  end

  defp validate_semver(errors, manifest) do
    case manifest["version"] do
      version when is_binary(version) ->
        if Version.parse(version) == :error,
          do: add_error(errors, "version", :invalid_semver, "must use semantic versioning"),
          else: errors

      _ ->
        add_error(errors, "version", :required, "is required")
    end
  end

  defp validate_localized(errors, manifest, field, min, max) do
    case manifest[field] do
      value when is_map(value) ->
        Enum.reduce(["en", "ru"], errors, fn locale, acc ->
          case value[locale] do
            text when is_binary(text) ->
              length = text |> String.trim() |> String.length()

              if length in min..max,
                do: acc,
                else:
                  add_error(
                    acc,
                    "#{field}.#{locale}",
                    :invalid_length,
                    "must contain between #{min} and #{max} characters"
                  )

            _ ->
              add_error(acc, "#{field}.#{locale}", :required, "is required")
          end
        end)

      _ ->
        add_error(errors, field, :required, "must contain English and Russian copy")
    end
  end

  defp validate_modules(errors, manifest, available_files) do
    modules = manifest["modules"]

    cond do
      not is_map(modules) ->
        add_error(errors, "modules", :required, "must define the four instruction modules")

      Enum.sort(Map.keys(modules)) != Enum.sort(@modules) ->
        add_error(
          errors,
          "modules",
          :invalid_modules,
          "must define exactly research, agents, simulation, and report"
        )

      true ->
        Enum.reduce(@modules, errors, fn module, acc ->
          {expected_instructions, expected_schema} = @expected_paths[module]
          config = modules[module]

          acc
          |> require_module_path(
            config,
            module,
            "instructions",
            expected_instructions,
            available_files
          )
          |> require_module_path(
            config,
            module,
            "output_schema",
            expected_schema,
            available_files
          )
        end)
    end
  end

  defp require_module_path(errors, config, module, key, expected, files) when is_map(config) do
    value = config[key]

    cond do
      value != expected ->
        add_error(
          errors,
          "modules.#{module}.#{key}",
          :invalid_reference,
          "must reference #{expected}"
        )

      not MapSet.member?(files, expected) ->
        add_error(
          errors,
          "modules.#{module}.#{key}",
          :missing_file,
          "references a file that is not present"
        )

      true ->
        errors
    end
  end

  defp require_module_path(errors, _config, module, key, _expected, _files) do
    add_error(errors, "modules.#{module}.#{key}", :required, "is required")
  end

  defp validate_variables(errors, manifest) do
    case manifest["variables"] || [] do
      variables when is_list(variables) ->
        errors =
          variables
          |> Enum.with_index()
          |> Enum.reduce(errors, fn {variable, index}, acc ->
            validate_variable(acc, variable, index)
          end)

        validate_unique_variable_keys(errors, variables)

      _ ->
        add_error(errors, "variables", :invalid_type, "must be a list")
    end
  end

  defp validate_variable(errors, variable, index) when is_map(variable) do
    key = variable["key"]
    type = variable["type"]

    errors =
      if is_binary(key) and Regex.match?(~r/^[a-z][a-z0-9_]{0,63}$/, key),
        do: errors,
        else: add_error(errors, "variables[#{index}].key", :invalid_key, "is invalid")

    errors =
      if type in @variable_types,
        do: errors,
        else:
          add_error(
            errors,
            "variables[#{index}].type",
            :unsupported_type,
            "must be one of #{Enum.join(@variable_types, ", ")}"
          )

    validate_variable_bounds(errors, variable, index)
  end

  defp validate_variable(errors, _variable, index) do
    add_error(errors, "variables[#{index}]", :invalid_type, "must be a map")
  end

  defp validate_unique_variable_keys(errors, variables) do
    keys =
      Enum.flat_map(variables, fn
        %{"key" => key} when is_binary(key) -> [key]
        _ -> []
      end)

    duplicates = keys -- Enum.uniq(keys)

    Enum.reduce(Enum.uniq(duplicates), errors, fn key, acc ->
      add_error(acc, "variables", :duplicate_key, "contains duplicate key #{inspect(key)}")
    end)
  end

  defp validate_variable_bounds(errors, %{"min" => min, "max" => max}, index)
       when is_number(min) and is_number(max) and min > max do
    add_error(errors, "variables[#{index}]", :invalid_bounds, "min cannot exceed max")
  end

  defp validate_variable_bounds(errors, _variable, _index), do: errors

  defp validate_capabilities(errors, manifest) do
    case manifest["capabilities"] || %{} do
      capabilities when is_map(capabilities) ->
        Enum.reduce(capabilities, errors, fn {stage, requested}, acc ->
          supported = @supported_capabilities[stage]

          cond do
            is_nil(supported) ->
              add_error(acc, "capabilities.#{stage}", :unsupported_stage, "is not supported")

            not is_list(requested) or not Enum.all?(requested, &is_binary/1) ->
              add_error(acc, "capabilities.#{stage}", :invalid_type, "must be a list of names")

            true ->
              unknown = requested -- supported

              if unknown == [],
                do: acc,
                else:
                  add_error(
                    acc,
                    "capabilities.#{stage}",
                    :unsupported_capability,
                    "requires unsupported capabilities: #{Enum.join(unknown, ", ")}"
                  )
          end
        end)

      _ ->
        add_error(errors, "capabilities", :invalid_type, "must be a map")
    end
  end

  defp validate_defaults(errors, manifest) do
    defaults = manifest["defaults"] || %{}

    if is_map(defaults) and defaults["execution_mode"] in [nil, "quick", "balanced", "deep"] do
      errors
    else
      add_error(
        errors,
        "defaults.execution_mode",
        :invalid_value,
        "must be quick, balanced, or deep"
      )
    end
  end

  defp validate_compatibility(errors, manifest) do
    compatibility = manifest["compatibility"] || %{}

    cond do
      not is_map(compatibility) ->
        add_error(errors, "compatibility", :invalid_type, "must be a map")

      compatibility["script_schema"] not in [nil, 1] ->
        add_error(errors, "compatibility.script_schema", :unsupported_version, "must equal 1")

      compatibility["population_schema"] not in [nil, 1] ->
        add_error(errors, "compatibility.population_schema", :unsupported_version, "must equal 1")

      not valid_optional_semver?(compatibility["minimum_hydra_version"]) ->
        add_error(
          errors,
          "compatibility.minimum_hydra_version",
          :invalid_semver,
          "must use semantic versioning"
        )

      true ->
        errors
    end
  end

  defp valid_optional_semver?(nil), do: true

  defp valid_optional_semver?(version) when is_binary(version) do
    Version.parse(version) != :error
  end

  defp valid_optional_semver?(_version), do: false

  defp compatibility_warnings(manifest) do
    minimum = get_in(manifest, ["compatibility", "minimum_hydra_version"])
    current = current_version()

    if is_binary(minimum) and Version.parse(minimum) != :error and
         Version.compare(minimum, current) == :gt do
      ["Blueprint targets Hydra #{minimum} or newer; this installation is #{current}."]
    else
      []
    end
  end

  defp current_version do
    case Application.spec(:hydra_agent, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end

  defp yaml_alias_or_tag?(yaml) do
    Regex.match?(~r/(?:^|[\s\[{,])(?:[&*][A-Za-z0-9_-]+|!![A-Za-z])/m, yaml)
  end

  defp error(code, message, detail \\ nil) do
    {:error, %{code: code, message: message, detail: inspect(detail)}}
  end

  defp add_error(errors, path, code, message) do
    errors ++ [%{"path" => path, "code" => to_string(code), "message" => message}]
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp encode_map(map, indent, preferred_order \\ []) do
    keys = ordered_keys(map, preferred_order)

    Enum.map(keys, fn key ->
      value = map[key]
      prefix = [spaces(indent), encode_key(key), ":"]

      cond do
        scalar?(value) -> [prefix, " ", encode_scalar(value), "\n"]
        value == %{} -> [prefix, " {}\n"]
        value == [] -> [prefix, " []\n"]
        is_map(value) -> [prefix, "\n", encode_map(value, indent + 2)]
        is_list(value) -> [prefix, "\n", encode_list(value, indent + 2)]
      end
    end)
  end

  defp encode_list(values, indent) do
    Enum.map(values, fn value ->
      cond do
        scalar?(value) -> [spaces(indent), "- ", encode_scalar(value), "\n"]
        is_map(value) -> encode_map_list_item(value, indent)
        is_list(value) -> [spaces(indent), "-\n", encode_list(value, indent + 2)]
      end
    end)
  end

  defp encode_map_list_item(map, indent) do
    [first | rest] = ordered_keys(map, [])
    first_value = map[first]

    first_line =
      if scalar?(first_value) do
        [spaces(indent), "- ", encode_key(first), ": ", encode_scalar(first_value), "\n"]
      else
        [
          spaces(indent),
          "- ",
          encode_key(first),
          ":\n",
          encode_nested(first_value, indent + 4)
        ]
      end

    [first_line, encode_map(Map.take(map, rest), indent + 2)]
  end

  defp encode_nested(value, indent) when is_map(value), do: encode_map(value, indent)
  defp encode_nested(value, indent) when is_list(value), do: encode_list(value, indent)

  defp ordered_keys(map, preferred) do
    keys = Map.keys(map)
    selected = Enum.filter(preferred, &(&1 in keys))
    selected ++ Enum.sort(keys -- selected)
  end

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp encode_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp encode_scalar(value), do: Jason.encode!(value)

  defp encode_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key), do: key, else: Jason.encode!(key)
  end

  defp spaces(count), do: :binary.copy(" ", count)
end
