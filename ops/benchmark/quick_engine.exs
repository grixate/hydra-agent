alias HydraAgent.SimLab.{Demo, Simulator}

parse_positive = fn value, label, default ->
  case value do
    nil ->
      default

    binary ->
      case Integer.parse(binary) do
        {integer, ""} when integer > 0 -> integer
        _ -> raise ArgumentError, "#{label} must be a positive integer"
      end
  end
end

args = Enum.drop_while(System.argv(), &(&1 == "--"))
[population_arg, iterations_arg | _] = args ++ [nil, nil]
population = parse_positive.(population_arg, "population", 10_000)
iterations = parse_positive.(iterations_arg, "iterations", 10)

unless population in 10..100_000 do
  raise ArgumentError, "population must be between 10 and 100000"
end

unless iterations in 1..100 do
  raise ArgumentError, "iterations must be between 1 and 100"
end

input = Demo.simulation_input() |> Map.put(:agent_count, population)

run = fn ->
  {microseconds, result} = :timer.tc(fn -> Simulator.run(input) end)
  {Float.round(microseconds / 1_000, 3), result}
end

Enum.each(1..2, fn _ -> run.() end)
:erlang.garbage_collect()
memory_before = :erlang.memory(:total)

samples = Enum.map(1..iterations, fn _ -> run.() end)
memory_after = :erlang.memory(:total)

durations = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
result = samples |> List.last() |> elem(1)

percentile = fn sorted, fraction ->
  index = max(ceil(length(sorted) * fraction) - 1, 0)
  Enum.at(sorted, index)
end

last_snapshot = List.last(result.snapshots)
conserved_population = Enum.sum_by(last_snapshot.clusters, & &1.count)

report = %{
  benchmark: "legacy_simlab_quick_engine",
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  population: population,
  iterations: iterations,
  seed: input.seed,
  rounds: length(result.snapshots),
  provider_calls: 0,
  population_conserved: conserved_population == population,
  final_population: conserved_population,
  decision_counts: result.decision_counts,
  duration_ms: %{
    min: List.first(durations),
    p50: percentile.(durations, 0.50),
    p95: percentile.(durations, 0.95),
    max: List.last(durations)
  },
  beam_memory_bytes: %{
    before: memory_before,
    after: memory_after,
    delta: memory_after - memory_before
  }
}

IO.puts(Jason.encode!(report, pretty: true))
