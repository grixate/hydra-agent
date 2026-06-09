defmodule HydraAgent.Simulation.World.Event do
  @moduledoc """
  World event delivered to simulated personas.
  """

  defstruct id: nil,
            type: :market_shift,
            source: :world,
            target: nil,
            target_agent_id: nil,
            description: "",
            properties: %{},
            stakes: 0.5,
            emotional_valence: :neutral,
            is_crisis?: false,
            is_threat?: false,
            is_provocation?: false,
            is_opportunity?: false,
            is_windfall?: false,
            tick: 0

  def new(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_atom(key), value} end)
      |> Map.put_new(:id, random_id())

    struct(__MODULE__, attrs)
  end

  def generate(tick, config) do
    seed = (config["rng_seed"] || 1) + tick * 101
    rng = :rand.seed_s(:exsss, {seed, seed + 3, seed + 7})
    {roll, rng} = :rand.uniform_s(rng)

    if roll > config["event_frequency"] do
      []
    else
      {crisis_roll, rng} = :rand.uniform_s(rng)
      crisis? = crisis_roll < config["crisis_probability"]
      types = event_types(config, crisis?)
      {index, rng} = :rand.uniform_s(length(types), rng)
      {stakes_roll, _rng} = :rand.uniform_s(rng)
      type = Enum.at(types, index - 1)
      stakes = min(1.0, stakes_roll * (0.3 + config["market_volatility"] * 0.7))

      [
        new(%{
          id: deterministic_id(config, tick, type, 0),
          type: type,
          tick: tick,
          stakes: Float.round(stakes, 2),
          emotional_valence: valence(type),
          is_crisis?: crisis?,
          is_threat?: type in [:pr_crisis, :security_breach, :budget_pressure, :market_crash],
          is_provocation?: type in [:competitor_move, :conflict_escalation],
          is_opportunity?: type in [:partnership_offer, :demand_surge, :innovation_breakthrough],
          is_windfall?: type == :demand_surge,
          description: describe(type, crisis?)
        })
      ]
    end
  end

  def evolve_world(world, tick, events, decisions) do
    world = if world in [%{}, nil], do: default_world(), else: world
    high_stakes = Enum.filter(events, &((&1.stakes || 0) >= 0.7))
    positive = Enum.count(events, &(&1.emotional_valence == :positive))
    negative = Enum.count(events, &(&1.emotional_valence == :negative))

    world
    |> put_in(["tick"], tick)
    |> update_in(
      ["market", "volatility"],
      &clamp((&1 || 0.5) + negative * 0.04 - positive * 0.02)
    )
    |> update_in(
      ["sentiment", "customers"],
      &clamp((&1 || 0.5) + positive * 0.03 - negative * 0.04)
    )
    |> update_in(["resources", "capacity"], &clamp((&1 || 0.6) - length(decisions) * 0.002))
    |> Map.update("risks", [], fn risks ->
      (risks ++ Enum.map(high_stakes, & &1.description)) |> Enum.uniq() |> Enum.take(-10)
    end)
    |> Map.update("open_threads", [], fn threads ->
      (threads ++ Enum.map(events, &humanize(&1.type))) |> Enum.uniq() |> Enum.take(-10)
    end)
    |> Map.put_new("resolved_threads", [])
  end

  defp normal_types do
    [
      :market_shift,
      :competitor_move,
      :product_launch,
      :budget_pressure,
      :regulation_change,
      :partnership_offer,
      :innovation_breakthrough,
      :demand_surge
    ]
  end

  defp crisis_types, do: [:pr_crisis, :security_breach, :market_crash, :conflict_escalation]

  defp event_types(_config, true), do: crisis_types()

  defp event_types(config, false) do
    case HydraAgent.Simulation.ScenarioTemplates.event_types(config["scenario_template"]) do
      types when is_list(types) and types != [] -> types
      _other -> normal_types()
    end
  end

  defp valence(type) when type in [:partnership_offer, :innovation_breakthrough, :demand_surge],
    do: :positive

  defp valence(type) when type in [:pr_crisis, :security_breach, :market_crash, :budget_pressure],
    do: :negative

  defp valence(_type), do: :neutral

  defp describe(type, true), do: "Crisis: #{humanize(type)}"
  defp describe(type, false), do: humanize(type)

  defp humanize(type), do: type |> Atom.to_string() |> String.replace("_", " ")

  defp deterministic_id(config, tick, type, index) do
    seed = config["rng_seed"] || 1
    :erlang.phash2({seed, tick, type, index}) |> Integer.to_string(16)
  end

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp default_world do
    HydraAgent.Simulation.ScenarioTemplates.initial_world("product_rollout")
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0) |> Float.round(3)

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end
end
