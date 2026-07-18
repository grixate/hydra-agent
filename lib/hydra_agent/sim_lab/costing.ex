defmodule HydraAgent.SimLab.Costing do
  @moduledoc """
  Transparent cost authorization for a deterministic aggregate SimLab run.

  The current engine makes no model calls during simulation. Its provider cost
  is therefore exactly zero; CPU and database capacity remain operator-owned
  infrastructure costs and are not misrepresented as API spend.
  """

  @modes %{
    "tiny" => %{agents: 50, rounds: 2, label: "Tiny"},
    "small" => %{agents: 250, rounds: 3, label: "Small"},
    "medium" => %{agents: 1_000, rounds: 4, label: "Medium"},
    "large" => %{agents: 5_000, rounds: 5, label: "Large"}
  }

  def estimate(mode) when is_atom(mode), do: estimate(Atom.to_string(mode))

  def estimate(mode) when is_binary(mode) do
    config = Map.fetch!(@modes, mode)

    %{
      mode: mode,
      label: config.label,
      agents: config.agents,
      rounds: config.rounds,
      expected_llm_calls: 0,
      pattern_ratio: 1.0,
      low_usd: 0.0,
      high_usd: 0.0,
      price_book_version: "deterministic-v1"
    }
  end

  def estimate(_), do: estimate("large")

  def authorize(mode, cap) do
    estimate = estimate(mode)

    if within_cap?(estimate.high_usd, cap),
      do: {:ok, estimate},
      else: {:error, :budget_cap_exceeded}
  end

  def within_cap?(actual, cap) do
    Decimal.compare(decimal(actual), decimal(cap)) in [:lt, :eq]
  rescue
    _ -> false
  end

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value), do: Decimal.new(to_string(value))
end
