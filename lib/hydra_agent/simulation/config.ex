defmodule HydraAgent.Simulation.Config do
  @moduledoc """
  Normalized simulation configuration and cost estimates.
  """

  @defaults %{
    "agent_count" => 20,
    "max_ticks" => 40,
    "tick_interval_ms" => 0,
    "max_budget_cents" => 50,
    "event_frequency" => 0.3,
    "crisis_probability" => 0.05,
    "market_volatility" => 0.5,
    "novelty_threshold" => 2,
    "stakes_threshold" => 0.7,
    "cheap_provider" => nil,
    "frontier_provider" => nil,
    "cheap_tokens_per_call" => 120,
    "frontier_tokens_per_call" => 280,
    "cheap_cost_per_million_tokens" => 0.14,
    "frontier_cost_per_million_tokens" => 3.0,
    "complex_share" => 0.15,
    "negotiation_share" => 0.05,
    "scenario_template" => "product_rollout",
    "rng_seed" => 1,
    "max_tick_cost_cents" => nil,
    "max_agent_cost_cents" => nil,
    "max_llm_calls" => nil,
    "max_wall_clock_seconds" => nil
  }

  @int_fields ~w(agent_count max_ticks tick_interval_ms max_budget_cents novelty_threshold cheap_tokens_per_call frontier_tokens_per_call rng_seed max_tick_cost_cents max_agent_cost_cents max_llm_calls max_wall_clock_seconds)
  @float_fields ~w(event_frequency crisis_probability market_volatility stakes_threshold cheap_cost_per_million_tokens frontier_cost_per_million_tokens complex_share negotiation_share)

  def normalize(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> then(&Map.merge(@defaults, &1))
    |> normalize_ints()
    |> normalize_floats()
  end

  def estimate(attrs) do
    config = normalize(attrs)
    decisions = config["agent_count"] * config["max_ticks"]
    complex_calls = Float.ceil(decisions * config["complex_share"]) |> trunc()
    negotiation_calls = Float.ceil(decisions * config["negotiation_share"]) |> trunc()

    cheap_tokens = complex_calls * config["cheap_tokens_per_call"]
    frontier_tokens = negotiation_calls * config["frontier_tokens_per_call"]

    cheap_cents =
      cents_for_tokens(cheap_tokens, config["cheap_cost_per_million_tokens"])

    frontier_cents =
      cents_for_tokens(frontier_tokens, config["frontier_cost_per_million_tokens"])

    total_cents = cheap_cents + frontier_cents

    %{
      "agent_count" => config["agent_count"],
      "max_ticks" => config["max_ticks"],
      "estimated_decisions" => decisions,
      "estimated_complex_calls" => complex_calls,
      "estimated_negotiation_calls" => negotiation_calls,
      "estimated_tokens" => cheap_tokens + frontier_tokens,
      "estimated_cost_cents" => total_cents,
      "max_budget_cents" => config["max_budget_cents"],
      "tier_assumptions" => %{
        "complex_share" => config["complex_share"],
        "negotiation_share" => config["negotiation_share"]
      }
    }
  end

  def validate(attrs) do
    config = normalize(attrs)

    errors =
      []
      |> positive("agent_count", config)
      |> positive("max_ticks", config)
      |> non_negative("tick_interval_ms", config)
      |> positive("max_budget_cents", config)
      |> ratio("event_frequency", config)
      |> ratio("crisis_probability", config)
      |> ratio("market_volatility", config)
      |> ratio("stakes_threshold", config)
      |> positive_or_nil("max_tick_cost_cents", config)
      |> positive_or_nil("max_agent_cost_cents", config)
      |> positive_or_nil("max_llm_calls", config)
      |> positive_or_nil("max_wall_clock_seconds", config)

    case errors do
      [] -> {:ok, config}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_ints(config) do
    Enum.reduce(@int_fields, config, fn key, acc -> Map.update!(acc, key, &to_int/1) end)
  end

  defp normalize_floats(config) do
    Enum.reduce(@float_fields, config, fn key, acc -> Map.update!(acc, key, &to_float/1) end)
  end

  defp cents_for_tokens(tokens, cost_per_million) do
    Float.ceil(tokens * cost_per_million / 1_000_000 * 100) |> trunc()
  end

  defp positive(errors, key, config) do
    if config[key] > 0, do: errors, else: ["#{key} must be positive" | errors]
  end

  defp positive_or_nil(errors, key, config) do
    if is_nil(config[key]) or config[key] > 0,
      do: errors,
      else: ["#{key} must be positive when provided" | errors]
  end

  defp non_negative(errors, key, config) do
    if config[key] >= 0, do: errors, else: ["#{key} must be non-negative" | errors]
  end

  defp ratio(errors, key, config) do
    value = config[key]

    if value >= 0.0 and value <= 1.0,
      do: errors,
      else: ["#{key} must be between 0 and 1" | errors]
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp to_int(value) when value in [nil, ""], do: nil
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp to_int(_value), do: 0

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      {parsed, _rest} -> parsed
      :error -> 0.0
    end
  end

  defp to_float(_value), do: 0.0
end
