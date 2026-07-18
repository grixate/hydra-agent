defmodule HydraAgent.Simulations.BudgetPlanBuilder do
  @moduledoc "Builds immutable, conservative execution-budget contracts."

  alias Decimal, as: D
  alias HydraAgent.Simulations.{ContentHash, PriceRegistry}

  @fallback_order ~w(deterministic_rule exact_cache policy_signature_cache representative_decision cheaper_or_local_model conservative_action stop_model_lane)

  @presets %{
    "quick" => %{
      input: 200_000,
      output: 40_000,
      calls: 5,
      retrievals: 8,
      runtime: 900,
      concurrency: 4,
      stages: %{
        "research" => %{"calls" => 8, "input_tokens" => 30_000, "output_tokens" => 4_000},
        "build" => %{"calls" => 4, "input_tokens" => 70_000, "output_tokens" => 14_000},
        "simulation" => %{"calls" => 0, "input_tokens" => 0, "output_tokens" => 0},
        "report" => %{"calls" => 1, "input_tokens" => 30_000, "output_tokens" => 8_000}
      }
    },
    "balanced" => %{
      input: 300_000,
      output: 60_000,
      calls: 88,
      retrievals: 12,
      runtime: 900,
      concurrency: 8,
      stages: %{
        "research" => %{"calls" => 12, "input_tokens" => 40_000, "output_tokens" => 5_000},
        "build" => %{"calls" => 6, "input_tokens" => 80_000, "output_tokens" => 15_000},
        "simulation" => %{"calls" => 80, "input_tokens" => 140_000, "output_tokens" => 30_000},
        "report" => %{"calls" => 2, "input_tokens" => 40_000, "output_tokens" => 10_000}
      }
    },
    "deep" => %{
      input: 600_000,
      output: 120_000,
      calls: 200,
      retrievals: 20,
      runtime: 1_800,
      concurrency: 8,
      stages: %{
        "research" => %{"calls" => 20, "input_tokens" => 60_000, "output_tokens" => 10_000},
        "build" => %{"calls" => 10, "input_tokens" => 140_000, "output_tokens" => 30_000},
        "simulation" => %{"calls" => 186, "input_tokens" => 320_000, "output_tokens" => 70_000},
        "report" => %{"calls" => 4, "input_tokens" => 80_000, "output_tokens" => 10_000}
      }
    }
  }

  def presets, do: @presets
  def preset(value) when value in ["standard", "balanced"], do: "balanced"
  def preset("deep"), do: "deep"
  def preset(_value), do: "quick"

  def build(workspace_id, preset, resolved_routes) do
    preset = preset(preset)
    config = Map.fetch!(@presets, preset)
    price_snapshot = PriceRegistry.snapshot(workspace_id, resolved_routes)
    stage_caps = stage_caps_with_cost(config.stages, price_snapshot)

    {pricing_status, maximum} =
      maximum_cost(stage_caps, price_snapshot["currency_status"])

    contract = %{
      "preset" => preset,
      "currency" => price_snapshot["currency"] || "USD",
      "pricing_status" => pricing_status,
      "hard_cost_cap" => decimal_string(maximum),
      "hard_input_token_cap" => config.input,
      "hard_output_token_cap" => config.output,
      "hard_model_call_cap" => config.calls,
      "hard_retrieval_request_cap" => config.retrievals,
      "hard_runtime_seconds" => config.runtime,
      "max_concurrency" => config.concurrency,
      "stage_caps" => stage_caps,
      "price_registry_snapshot" => price_snapshot,
      "model_route_snapshot" => resolved_routes,
      "estimates" => %{
        "currency" => price_snapshot["currency"] || "USD",
        "minimum_cost" => "0",
        "maximum_cost" => decimal_string(maximum),
        "cost_status" => pricing_status,
        "runtime_band_seconds" => runtime_band(preset)
      },
      "fallback_policy" => %{
        "order" => @fallback_order,
        "deterministic_completion_after_exhaustion" => true
      }
    }

    hash_contract =
      put_in(
        contract,
        ["price_registry_snapshot"],
        Map.delete(contract["price_registry_snapshot"], "captured_at")
      )

    Map.put(contract, "content_hash", ContentHash.digest(hash_contract))
  end

  def snapshot(plan) do
    %{
      "preset" => plan.preset,
      "currency" => plan.currency,
      "pricing_status" => plan.pricing_status,
      "hard_cost_cap" => decimal_string(plan.hard_cost_cap),
      "hard_input_token_cap" => plan.hard_input_token_cap,
      "hard_output_token_cap" => plan.hard_output_token_cap,
      "hard_model_call_cap" => plan.hard_model_call_cap,
      "hard_retrieval_request_cap" => plan.hard_retrieval_request_cap,
      "hard_runtime_seconds" => plan.hard_runtime_seconds,
      "max_concurrency" => plan.max_concurrency,
      "stage_caps" => plan.stage_caps,
      "price_registry_snapshot" => plan.price_registry_snapshot,
      "estimates" => plan.estimates,
      "fallback_policy" => plan.fallback_policy,
      "content_hash" => plan.content_hash
    }
  end

  defp maximum_cost(_stages, "mixed"), do: {"unknown", nil}

  defp maximum_cost(stages, _currency_status) do
    results =
      Enum.map(stages, fn {_stage, caps} ->
        cond do
          caps["calls"] == 0 -> {:known, D.new(0)}
          is_binary(caps["cost"]) -> {:known, D.new(caps["cost"])}
          true -> :unknown
        end
      end)

    known = for {:known, value} <- results, do: value
    unknown = Enum.count(results, &(&1 == :unknown))

    status =
      cond do
        unknown == 0 -> "known"
        known == [] -> "unknown"
        true -> "partial"
      end

    maximum = if unknown == 0, do: Enum.reduce(known, D.new(0), &D.add/2), else: nil
    {status, maximum}
  end

  defp stage_caps_with_cost(stages, snapshot) do
    Map.new(stages, fn {stage, caps} ->
      cost = price_stage(stage, caps, snapshot)
      {stage, Map.put(caps, "cost", decimal_string(cost))}
    end)
  end

  defp price_stage(stage, caps, snapshot) do
    role = if stage == "research", do: "retrieval", else: stage
    price = get_in(snapshot, ["entries", role]) || %{}

    PriceRegistry.estimate_stage_max(
      price,
      caps["input_tokens"],
      caps["output_tokens"],
      caps["calls"]
    )
  end

  defp runtime_band("quick"), do: %{"minimum" => 5, "maximum" => 900}
  defp runtime_band("balanced"), do: %{"minimum" => 20, "maximum" => 900}
  defp runtime_band("deep"), do: %{"minimum" => 60, "maximum" => 1_800}

  defp decimal_string(nil), do: nil
  defp decimal_string(%D{} = value), do: D.to_string(value, :normal)
end
