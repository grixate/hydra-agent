defmodule HydraAgent.Simulation.Engine.BatchInference do
  @moduledoc """
  Budget-aware batched LLM dispatch for simulation ticks.
  """

  alias HydraAgent.{Providers, Usage}
  alias HydraAgent.Simulation.Agent.Action
  alias HydraAgent.Simulation.Engine.SimAgent

  @cheap_concurrency 20
  @frontier_concurrency 5

  def run(requests, context, config, budget_remaining_cents, opts \\ []) do
    effective_budget = effective_tick_budget(config, budget_remaining_cents)
    {allowed, downgraded} = fit_budget(requests, config, effective_budget)
    {allowed, skipped_for_agent_cap} = enforce_agent_cost_cap(allowed, config)
    {allowed, skipped_for_call_cap} = enforce_call_cap(allowed, config)
    llm_fn = Keyword.get(opts, :llm_fn)

    results =
      allowed
      |> Enum.group_by(& &1.tier)
      |> Enum.flat_map(fn {tier, tier_requests} ->
        tier_requests
        |> Task.async_stream(
          &execute_single(&1, context, config, llm_fn),
          max_concurrency: concurrency(tier),
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _reason} -> timeout_result()
        end)
      end)

    %{
      results: results ++ downgraded ++ skipped_for_agent_cap ++ skipped_for_call_cap,
      llm_calls: Enum.count(results, &(&1["method"] in ["cheap_llm", "frontier_llm"])),
      tokens_used: Enum.sum(Enum.map(results, &(&1["tokens_used"] || 0))),
      cost_cents: Enum.sum(Enum.map(results, &(&1["cost_cents"] || 0))),
      budget_exceeded?: Enum.sum(Enum.map(results, &(&1["cost_cents"] || 0))) > effective_budget,
      downgraded_count:
        length(downgraded) + length(skipped_for_agent_cap) + length(skipped_for_call_cap),
      skipped_llm_count:
        length(downgraded) + length(skipped_for_agent_cap) + length(skipped_for_call_cap)
    }
  end

  defp fit_budget(requests, config, budget_remaining_cents) do
    Enum.reduce(requests, {[], [], budget_remaining_cents}, fn req, {allowed, downgraded, left} ->
      cost = estimate_request_cents(req.tier, config)

      if cost <= left do
        {[req | allowed], downgraded, left - cost}
      else
        decision =
          SimAgent.routine_action(req.persona, req.event, req.state)
          |> Map.merge(%{
            "agent_key" => req.agent_key,
            "profile_id" => req.profile_id,
            "tier" => "routine",
            "method" => "rules_engine",
            "downgraded_from" => Atom.to_string(req.tier),
            "reasoning" => "Downgraded before dispatch to preserve the simulation hard budget.",
            "tokens_used" => 0,
            "cost_cents" => 0
          })

        {allowed, [decision | downgraded], left}
      end
    end)
    |> then(fn {allowed, downgraded, _left} ->
      {Enum.reverse(allowed), Enum.reverse(downgraded)}
    end)
  end

  defp enforce_call_cap(requests, config) do
    case config["max_llm_calls"] do
      max_calls when is_integer(max_calls) and max_calls >= 0 ->
        {allowed, skipped} = Enum.split(requests, max_calls)

        skipped =
          Enum.map(skipped, fn req ->
            req
            |> downgraded_decision()
            |> Map.put("reasoning", "Downgraded before dispatch to preserve the LLM call cap.")
          end)

        {allowed, skipped}

      _other ->
        {requests, []}
    end
  end

  defp enforce_agent_cost_cap(requests, config) do
    case config["max_agent_cost_cents"] do
      cap when is_integer(cap) and cap > 0 ->
        requests
        |> Enum.reduce({[], []}, fn req, {allowed, skipped} ->
          estimated = estimate_request_cents(req.tier, config)
          current = req[:current_cost_cents] || req.current_cost_cents || 0

          if current + estimated <= cap do
            {[req | allowed], skipped}
          else
            decision =
              req
              |> downgraded_decision()
              |> Map.put(
                "reasoning",
                "Downgraded before dispatch to preserve the per-agent simulation cost cap."
              )

            {allowed, [decision | skipped]}
          end
        end)
        |> then(fn {allowed, skipped} -> {Enum.reverse(allowed), Enum.reverse(skipped)} end)

      _other ->
        {requests, []}
    end
  end

  defp downgraded_decision(req) do
    SimAgent.routine_action(req.persona, req.event, req.state)
    |> Map.merge(%{
      "agent_key" => req.agent_key,
      "profile_id" => req.profile_id,
      "tier" => "routine",
      "method" => "rules_engine",
      "downgraded_from" => Atom.to_string(req.tier),
      "tokens_used" => 0,
      "cost_cents" => 0
    })
  end

  defp effective_tick_budget(config, budget_remaining_cents) do
    case config["max_tick_cost_cents"] do
      cap when is_integer(cap) and cap > 0 -> min(budget_remaining_cents, cap)
      _other -> budget_remaining_cents
    end
  end

  defp execute_single(req, context, config, nil) do
    provider_name = provider_name(req.tier, config)

    case provider_name && Providers.get_config_by_name(context.workspace_id, provider_name) do
      nil ->
        req
        |> fallback_decision()
        |> Map.put(
          "reasoning",
          "Downgraded because no provider route is configured for this tier."
        )

      provider ->
        request = %{
          "messages" => req.messages,
          "temperature" => 0.2,
          "max_tokens" => max_tokens(req.tier, config)
        }

        started = System.monotonic_time(:millisecond)

        case Providers.chat(provider, request) do
          {:ok, response} ->
            latency_ms = System.monotonic_time(:millisecond) - started
            tokens = response_tokens(response, max_tokens(req.tier, config))

            cost_cents = estimate_tokens_cents(tokens, req.tier, config)

            Usage.record_provider_response(
              %{
                "workspace_id" => context.workspace_id,
                "agent_id" => context.agent_id,
                "run_id" => context.run_id,
                "metadata" => %{
                  "simulation_id" => context.simulation_id,
                  "simulation_tier" => Atom.to_string(req.tier),
                  "estimated_cost_cents" => cost_cents,
                  "latency_ms" => latency_ms
                }
              },
              response,
              "simulation"
            )

            parse_response(req, response, tokens, cost_cents)

          {:error, error} ->
            Usage.record_error(
              %{
                "workspace_id" => context.workspace_id,
                "agent_id" => context.agent_id,
                "run_id" => context.run_id,
                "metadata" => %{"simulation_id" => context.simulation_id}
              },
              error,
              "simulation"
            )

            fallback_decision(req)
        end
    end
  end

  defp execute_single(req, _context, config, llm_fn) when is_function(llm_fn, 1) do
    case llm_fn.(req) do
      {:ok, response} ->
        tokens = response_tokens(response, max_tokens(req.tier, config))

        parse_response(
          req,
          response,
          tokens,
          estimate_tokens_cents(tokens, req.tier, config)
        )

      {:error, _error} ->
        fallback_decision(req)
    end
  end

  defp parse_response(req, response, tokens, cost_cents) do
    content = get_in(response, ["message", "content"]) || response["content"] || ""

    decision =
      case Jason.decode(content) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _other -> %{"action" => extract_action(content, req.event.type), "reasoning" => content}
      end

    decision
    |> Map.put_new("action", "wait_and_observe")
    |> Map.put("agent_key", req.agent_key)
    |> Map.put("profile_id", req.profile_id)
    |> Map.put("tier", Atom.to_string(req.tier))
    |> Map.put("method", if(req.tier == :frontier, do: "frontier_llm", else: "cheap_llm"))
    |> Map.put("tokens_used", tokens)
    |> Map.put("cost_cents", cost_cents)
  end

  defp response_tokens(response, fallback) do
    usage = response["usage"] || response[:usage] || %{}

    cond do
      usage["total_tokens"] || usage[:total_tokens] ->
        usage["total_tokens"] || usage[:total_tokens]

      usage["input_tokens"] || usage[:input_tokens] || usage["output_tokens"] ||
          usage[:output_tokens] ->
        (usage["input_tokens"] || usage[:input_tokens] || 0) +
          (usage["output_tokens"] || usage[:output_tokens] || 0)

      true ->
        fallback
    end
  end

  defp fallback_decision(req) do
    req.persona
    |> SimAgent.routine_action(req.event, req.state)
    |> Map.merge(%{
      "agent_key" => req.agent_key,
      "profile_id" => req.profile_id,
      "downgraded_from" => Atom.to_string(req.tier),
      "tokens_used" => 0,
      "cost_cents" => 0
    })
  end

  defp timeout_result do
    %{
      "agent_key" => nil,
      "action" => "wait_and_observe",
      "tier" => "routine",
      "method" => "rules_engine",
      "reasoning" => "LLM request timed out.",
      "tokens_used" => 0,
      "cost_cents" => 0
    }
  end

  defp extract_action(text, event_type) do
    text = String.downcase(text || "")

    event_type
    |> Action.available_for()
    |> Enum.find(:wait_and_observe, fn action ->
      String.contains?(text, String.replace(Atom.to_string(action), "_", " "))
    end)
    |> Atom.to_string()
  end

  defp provider_name(:cheap, config), do: config["cheap_provider"]

  defp provider_name(:frontier, config),
    do: config["frontier_provider"] || config["cheap_provider"]

  defp concurrency(:frontier), do: @frontier_concurrency
  defp concurrency(_tier), do: @cheap_concurrency

  defp max_tokens(:frontier, config), do: config["frontier_tokens_per_call"]
  defp max_tokens(_tier, config), do: config["cheap_tokens_per_call"]

  defp estimate_request_cents(:frontier, config),
    do: estimate_tokens_cents(config["frontier_tokens_per_call"], :frontier, config)

  defp estimate_request_cents(_tier, config),
    do: estimate_tokens_cents(config["cheap_tokens_per_call"], :cheap, config)

  defp estimate_tokens_cents(tokens, :frontier, config),
    do: ceil(tokens * config["frontier_cost_per_million_tokens"] / 1_000_000 * 100)

  defp estimate_tokens_cents(tokens, _tier, config),
    do: ceil(tokens * config["cheap_cost_per_million_tokens"] / 1_000_000 * 100)
end
