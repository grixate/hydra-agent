defmodule HydraAgent.Simulations.ScriptExporter do
  @moduledoc "Deterministic JSON and readable YAML export for Simulation Script V1."

  @top_order ~w(hydra_simulation_script metadata clock world agent_types relationships resources events actions perception policies transitions observations stopping_conditions)

  def json(script) when is_map(script), do: Jason.encode!(script, pretty: true) <> "\n"

  def yaml(script) when is_map(script) do
    script
    |> encode_map(0, @top_order)
    |> IO.iodata_to_binary()
  end

  defp encode_map(map, indent, preferred \\ []) do
    keys = ordered_keys(map, preferred)

    Enum.map(keys, fn key ->
      prefix = spaces(indent) <> encode_key(key) <> ":"
      encode_key_value(prefix, map[key], indent)
    end)
  end

  defp encode_key_value(prefix, value, _indent) when value == %{}, do: [prefix, " {}\n"]
  defp encode_key_value(prefix, value, _indent) when value == [], do: [prefix, " []\n"]

  defp encode_key_value(prefix, value, indent) when is_map(value),
    do: [prefix, "\n", encode_map(value, indent + 2)]

  defp encode_key_value(prefix, value, indent) when is_list(value),
    do: [prefix, "\n", encode_list(value, indent + 2)]

  defp encode_key_value(prefix, value, _indent), do: [prefix, " ", scalar(value), "\n"]

  defp encode_list(values, indent) do
    Enum.map(values, fn
      value when is_map(value) and map_size(value) == 0 -> [spaces(indent), "- {}\n"]
      value when is_map(value) -> encode_list_map(value, indent)
      value when is_list(value) -> [spaces(indent), "-\n", encode_list(value, indent + 2)]
      value -> [spaces(indent), "- ", scalar(value), "\n"]
    end)
  end

  defp encode_list_map(map, indent) do
    [first | rest] = ordered_keys(map, [])
    first_value = map[first]
    prefix = spaces(indent) <> "- " <> encode_key(first) <> ":"

    [
      encode_key_value(prefix, first_value, indent + 2),
      Enum.map(rest, fn key ->
        encode_key_value(spaces(indent + 2) <> encode_key(key) <> ":", map[key], indent + 2)
      end)
    ]
  end

  defp scalar(value), do: Jason.encode!(value)

  defp encode_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key), do: key, else: Jason.encode!(key)
  end

  defp ordered_keys(map, preferred) do
    existing = Map.keys(map)
    Enum.filter(preferred, &(&1 in existing)) ++ Enum.sort(existing -- preferred)
  end

  defp spaces(count), do: String.duplicate(" ", count)
end
