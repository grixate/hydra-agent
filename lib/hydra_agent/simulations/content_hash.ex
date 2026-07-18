defmodule HydraAgent.Simulations.ContentHash do
  @moduledoc "Deterministic SHA-256 hashing for immutable simulation inputs."

  def digest(value) do
    value
    |> canonical()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical(nested)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical(value), do: Jason.encode!(value)
end
