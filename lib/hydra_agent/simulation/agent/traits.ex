defmodule HydraAgent.Simulation.Agent.Traits do
  @moduledoc """
  Trait vector and deterministic decision weights for simulated agents.
  """

  @fields [
    :openness,
    :conscientiousness,
    :extraversion,
    :agreeableness,
    :neuroticism,
    :risk_tolerance,
    :innovation_bias,
    :consensus_seeking,
    :analytical_depth,
    :emotional_reactivity,
    :authority_deference,
    :competitive_drive
  ]

  defstruct Enum.map(@fields, &{&1, 0.5})

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_atom(key), clamp(value)} end)
      |> Map.take(@fields)

    struct(__MODULE__, attrs)
  end

  def apply_noise(%__MODULE__{} = traits, seed) do
    rng = :rand.seed_s(:exsss, {seed, seed + 17, seed + 31})

    {attrs, _rng} =
      Enum.reduce(@fields, {%{}, rng}, fn field, {acc, rng} ->
        {roll, rng} = :rand.uniform_s(rng)
        value = Map.fetch!(traits, field)
        {Map.put(acc, field, clamp(value + (roll - 0.5) * 0.16)), rng}
      end)

    struct(__MODULE__, attrs)
  end

  def personality_base(action, %__MODULE__{} = t) do
    case action do
      :aggressive_response -> avg([t.competitive_drive, 1 - t.agreeableness, t.risk_tolerance])
      :cautious_response -> avg([t.conscientiousness, 1 - t.risk_tolerance, t.analytical_depth])
      :seek_consensus -> avg([t.consensus_seeking, t.agreeableness, 1 - t.competitive_drive])
      :defer_to_authority -> avg([t.authority_deference, t.conscientiousness])
      :wait_and_observe -> avg([t.analytical_depth, 1 - t.emotional_reactivity])
      :public_statement -> avg([t.extraversion, t.competitive_drive])
      :private_negotiation -> avg([t.consensus_seeking, t.analytical_depth, t.extraversion])
      :innovative_proposal -> avg([t.openness, t.innovation_bias, t.risk_tolerance])
      :protect_resources -> avg([t.conscientiousness, 1 - t.risk_tolerance])
      :do_nothing -> 0.15
      _ -> 0.25
    end
  end

  def compute_margin(weights) do
    case Enum.sort_by(weights, fn {_action, weight} -> -weight end) do
      [{_, top}, {_, second} | _] when top > 0 -> (top - second) / top
      _ -> 1.0
    end
  end

  def weighted_choice(weights, seed) do
    total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    rng = :rand.seed_s(:exsss, {seed, seed + 11, seed + 19})
    {roll, _rng} = :rand.uniform_s(rng)
    target = roll * max(total, 0.01)

    {selected, _seen} =
      Enum.reduce_while(weights, {nil, 0.0}, fn {action, weight}, {_selected, seen} ->
        next = seen + weight
        if next >= target, do: {:halt, {action, next}}, else: {:cont, {action, next}}
      end)

    selected || weights |> List.first() |> elem(0)
  end

  defp avg(values), do: Enum.sum(values) / max(length(values), 1)

  defp clamp(value) when is_integer(value), do: clamp(value / 1)
  defp clamp(value) when is_float(value), do: value |> max(0.0) |> min(1.0) |> Float.round(4)
  defp clamp(_value), do: 0.5

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end
end
