defmodule HydraAgent.Simulations.JsonSchema do
  @moduledoc "A bounded validator for the portable JSON Schema subset used by V1 artifacts."

  def validate(schema, value) when is_map(schema) do
    case validate_node(schema, value, schema, "$") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_schema, _value) do
    {:error, [%{"path" => "$", "message" => "schema must be a map"}]}
  end

  defp validate_node(%{"$ref" => ref} = schema, value, root, path) do
    case resolve_ref(ref, root) do
      {:ok, referenced} ->
        referenced_errors = validate_node(referenced, value, root, path)
        sibling_errors = validate_node(Map.delete(schema, "$ref"), value, root, path)
        referenced_errors ++ sibling_errors

      :error ->
        [error(path, "schema reference could not be resolved")]
    end
  end

  defp validate_node(schema, value, root, path) do
    type_errors = validate_type(schema["type"], value, path)

    if type_errors == [] do
      []
      |> Kernel.++(validate_enum(schema["enum"], value, path))
      |> Kernel.++(validate_number(schema, value, path))
      |> Kernel.++(validate_string(schema, value, path))
      |> Kernel.++(validate_array(schema, value, root, path))
      |> Kernel.++(validate_object(schema, value, root, path))
    else
      type_errors
    end
  end

  defp validate_type(nil, _value, _path), do: []

  defp validate_type(types, value, path) when is_list(types) do
    if Enum.any?(types, &type_matches?(&1, value)),
      do: [],
      else: [error(path, "must match one of the declared types")]
  end

  defp validate_type(type, value, path) do
    if type_matches?(type, value), do: [], else: [error(path, "must be #{type}")]
  end

  defp type_matches?("object", value), do: is_map(value)
  defp type_matches?("array", value), do: is_list(value)
  defp type_matches?("string", value), do: is_binary(value)
  defp type_matches?("integer", value), do: is_integer(value)
  defp type_matches?("number", value), do: is_number(value)
  defp type_matches?("boolean", value), do: is_boolean(value)
  defp type_matches?("null", value), do: is_nil(value)
  defp type_matches?(_unknown, _value), do: false

  defp validate_enum(nil, _value, _path), do: []

  defp validate_enum(values, value, path) when is_list(values) do
    if value in values, do: [], else: [error(path, "must be one of the allowed values")]
  end

  defp validate_enum(_values, _value, path), do: [error(path, "schema enum must be a list")]

  defp validate_number(schema, value, path) when is_number(value) do
    []
    |> maybe_error(number_below?(value, schema["minimum"]), path, "is below the minimum")
    |> maybe_error(number_above?(value, schema["maximum"]), path, "is above the maximum")
  end

  defp validate_number(_schema, _value, _path), do: []

  defp validate_string(schema, value, path) when is_binary(value) do
    length = String.length(value)

    []
    |> maybe_error(integer_limit?(schema["minLength"], &(length < &1)), path, "is too short")
    |> maybe_error(integer_limit?(schema["maxLength"], &(length > &1)), path, "is too long")
  end

  defp validate_string(_schema, _value, _path), do: []

  defp validate_array(schema, value, root, path) when is_list(value) do
    length = length(value)

    errors =
      []
      |> maybe_error(
        integer_limit?(schema["minItems"], &(length < &1)),
        path,
        "has too few items"
      )
      |> maybe_error(
        integer_limit?(schema["maxItems"], &(length > &1)),
        path,
        "has too many items"
      )

    case schema["items"] do
      nil ->
        errors

      item_schema when is_map(item_schema) ->
        value
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {item, index}, acc ->
          acc ++ validate_node(item_schema, item, root, "#{path}[#{index}]")
        end)

      _ ->
        errors ++ [error(path, "schema items must be a map")]
    end
  end

  defp validate_array(_schema, _value, _root, _path), do: []

  defp validate_object(schema, value, root, path) when is_map(value) do
    required_errors =
      for key <- schema["required"] || [],
          not Map.has_key?(value, key),
          do: error("#{path}.#{key}", "is required")

    properties = schema["properties"] || %{}

    property_errors =
      Enum.reduce(properties, [], fn {key, property_schema}, acc ->
        if Map.has_key?(value, key) and is_map(property_schema) do
          acc ++ validate_node(property_schema, value[key], root, "#{path}.#{key}")
        else
          acc
        end
      end)

    additional_errors =
      if schema["additionalProperties"] == false do
        unknown = Map.keys(value) -- Map.keys(properties)
        Enum.map(unknown, &error("#{path}.#{&1}", "is not allowed"))
      else
        []
      end

    required_errors ++ property_errors ++ additional_errors
  end

  defp validate_object(_schema, _value, _root, _path), do: []

  defp resolve_ref("#/" <> pointer, root) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, current} ->
      if is_map(current) and Map.has_key?(current, segment),
        do: {:cont, {:ok, current[segment]}},
        else: {:halt, :error}
    end)
  end

  defp resolve_ref(_ref, _root), do: :error

  defp number_below?(_value, nil), do: false
  defp number_below?(value, minimum) when is_number(minimum), do: value < minimum
  defp number_below?(_value, _minimum), do: false

  defp number_above?(_value, nil), do: false
  defp number_above?(value, maximum) when is_number(maximum), do: value > maximum
  defp number_above?(_value, _maximum), do: false

  defp integer_limit?(limit, predicate) when is_integer(limit) and limit >= 0,
    do: predicate.(limit)

  defp integer_limit?(_limit, _predicate), do: false

  defp maybe_error(errors, true, path, message), do: errors ++ [error(path, message)]
  defp maybe_error(errors, false, _path, _message), do: errors

  defp error(path, message), do: %{"path" => path, "message" => message}
end
