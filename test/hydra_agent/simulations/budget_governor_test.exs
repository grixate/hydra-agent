defmodule HydraAgent.Simulations.BudgetGovernorTest do
  use HydraAgent.DataCase, async: false
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias Decimal, as: D
  alias HydraAgent.{Repo, Runtime, Simulations}

  alias HydraAgent.Simulations.{
    Blueprints,
    BudgetGovernor,
    BudgetPlan,
    BudgetPlanBuilder,
    BudgetReservation,
    ModelRouter,
    PriceRegistry
  }

  setup do
    workspace = workspace_fixture(%{name: "Budget Governor", slug: "simulation-budget"})
    [general, _decision_replay] = Blueprints.ensure_builtins!()
    %{workspace: workspace, general: general}
  end

  test "known route prices create an immutable monetary maximum", context do
    _provider = local_provider(context.workspace, "Local structured model", "local-v1")
    price = retrieval_price(context.workspace, "0.01", -2)
    simulation = simulation(context)
    plan = Simulations.current_budget_plan(simulation)

    assert plan.pricing_status == "known"
    assert D.equal?(plan.hard_cost_cap, D.new("0.08"))
    assert D.equal?(D.new(plan.stage_caps["research"]["cost"]), D.new("0.08"))
    assert plan.price_registry_snapshot["entries"]["retrieval"]["price_entry_id"] == price.id

    assert_raise Postgrex.Error, ~r/configuration records are immutable/, fn ->
      plan |> Ecto.Changeset.change(preset: "balanced") |> Repo.update!()
    end
  end

  test "unknown prices remain honest while non-monetary hard caps stay active", context do
    simulation = simulation(context)
    plan = Simulations.current_budget_plan(simulation)

    assert plan.pricing_status in ["partial", "unknown"]
    assert plan.hard_cost_cap == nil
    assert plan.hard_model_call_cap == 5
    assert plan.hard_input_token_cap == 200_000
    assert plan.hard_output_token_cap == 40_000
    assert plan.hard_runtime_seconds == 900
    assert plan.max_concurrency == 4
  end

  test "retrieval, stage, token, and call caps cannot be overrun", context do
    _provider = local_provider(context.workspace, "Local structured model", "local-v1")
    _price = retrieval_price(context.workspace, "0.01", -2)
    simulation = simulation(context)
    plan = Simulations.current_budget_plan(simulation)

    Enum.each(1..8, fn index ->
      assert {:ok, reservation} =
               BudgetGovernor.reserve(plan, "research", retrieval_request(index))

      assert {:ok, completed} = BudgetGovernor.complete(reservation, %{})
      assert D.equal?(completed.actual_cost, D.new("0.01"))
    end)

    assert {:error, %{"reason" => "retrieval_cap_exhausted"}} =
             BudgetGovernor.reserve(plan, "research", retrieval_request(9))

    assert {:fallback, %BudgetReservation{fallback: "deterministic_rule"}} =
             BudgetGovernor.reserve(plan, "research", retrieval_request(10),
               on_exhaustion: :fallback
             )

    summary = BudgetGovernor.summary(plan)
    assert summary["retrieval_requests"] == 8
    assert summary["remaining_retrieval_requests"] == 0
    assert D.equal?(D.new(summary["used_cost"]), D.new("0.08"))
    assert D.equal?(D.new(summary["remaining_cost"]), D.new("0"))
    assert summary["fallbacks"] == 1

    assert {:fallback, %BudgetReservation{fallback: "deterministic_rule"}} =
             BudgetGovernor.reserve(
               plan,
               "build",
               %{
                 "max_input_tokens" => 1,
                 "max_output_tokens" => 1,
                 "idempotency_key" => hash("runtime-fallback")
               },
               elapsed_runtime_seconds: 900,
               on_exhaustion: :fallback
             )

    assert {:error, %{"reason" => "stage_output_token_cap_exhausted"}} =
             BudgetGovernor.reserve(plan, "report", %{
               "max_input_tokens" => 1,
               "max_output_tokens" => 8_001,
               "idempotency_key" => hash("output-overrun")
             })
  end

  test "concurrent callers cannot reserve the same remaining stage call", context do
    _provider = local_provider(context.workspace, "Local structured model", "local-v1")
    _price = retrieval_price(context.workspace, "0.01", -2)
    simulation = simulation(context)
    plan = Simulations.current_budget_plan(simulation)
    parent = self()

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              BudgetGovernor.reserve(plan, "report", %{
                "max_input_tokens" => 1_000,
                "max_output_tokens" => 500,
                "idempotency_key" => hash("concurrent-report-#{index}")
              })
          end
        end)
      end

    Enum.each(tasks, fn _task ->
      assert_receive {:ready, pid}
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      send(pid, :go)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, %BudgetReservation{status: "reserved"}}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{"reason" => "stage_call_cap_exhausted"}}, &1)
           ) == 1

    assert Repo.aggregate(BudgetReservation, :count) == 2
  end

  test "completion releases unused reservation capacity and rejects provider overruns", context do
    _provider = local_provider(context.workspace, "Local structured model", "local-v1")
    _price = retrieval_price(context.workspace, "0.01", -2)
    simulation = simulation(context)
    plan = Simulations.current_budget_plan(simulation)

    assert {:ok, reservation} =
             BudgetGovernor.reserve(plan, "build", %{
               "max_input_tokens" => 10_000,
               "max_output_tokens" => 4_000,
               "idempotency_key" => hash("build-reservation")
             })

    assert {:error, %{"reason" => "provider_usage_exceeded_reservation"}} =
             BudgetGovernor.complete(reservation, %{
               "input_tokens" => 10_001,
               "output_tokens" => 0
             })

    assert {:error, %{"reason" => "invalid_provider_cost"}} =
             BudgetGovernor.complete(reservation, %{
               "input_tokens" => 800,
               "output_tokens" => 200,
               "actual_cost" => "not-a-cost"
             })

    assert {:error, %{"reason" => "provider_cost_exceeded_reservation"}} =
             BudgetGovernor.complete(reservation, %{
               "input_tokens" => 800,
               "output_tokens" => 200,
               "actual_cost" => "1.00"
             })

    assert {:ok, completed} =
             BudgetGovernor.complete(reservation, %{
               "input_tokens" => 800,
               "output_tokens" => 200
             })

    assert completed.actual_input_tokens == 800
    assert completed.actual_output_tokens == 200
    assert {:ok, replayed} = BudgetGovernor.complete(completed, %{})
    assert replayed.id == completed.id
    assert replayed.completed_at == completed.completed_at
    assert BudgetGovernor.summary(plan)["input_tokens"] == 800

    assert {:error, %{"reason" => "invalid_nonnegative_integer"}} =
             BudgetGovernor.reserve(plan, "report", %{
               "max_input_tokens" => "unknown",
               "max_output_tokens" => 10,
               "idempotency_key" => hash("invalid-envelope")
             })
  end

  test "Automatic routing excludes remote providers without usable credentials", context do
    assert {:ok, remote} =
             Runtime.create_provider(%{
               workspace_id: context.workspace.id,
               name: "Disconnected remote",
               kind: "openai_compatible",
               model: "remote-v1",
               api_key_env: "HYDRA_TEST_MISSING_REMOTE_KEY",
               enabled: true
             })

    System.delete_env("HYDRA_TEST_MISSING_REMOTE_KEY")

    routes = ModelRouter.build(context.workspace.id, "quick", %{})
    assert routes["resolved_routes"]["build"]["status"] == "unavailable"
    assert ModelRouter.available_routes(context.workspace.id) == []

    explicit =
      ModelRouter.build(context.workspace.id, "quick", %{
        "build" => to_string(remote.id)
      })

    assert explicit["resolved_routes"]["build"]["status"] == "unavailable"
  end

  test "mixed currencies never produce a fictional monetary hard cap", context do
    _usd = model_price(context.workspace, "provider-a", "model-a", "USD", "1")
    _eur = model_price(context.workspace, "provider-b", "model-b", "EUR", "1")
    _retrieval = retrieval_price(context.workspace, "0.01", -2)

    routes = %{
      "build" => resolved_route("provider-a", "model-a"),
      "simulation" => %{"status" => "disabled"},
      "report" => resolved_route("provider-b", "model-b")
    }

    contract = BudgetPlanBuilder.build(context.workspace.id, "quick", routes)
    assert contract["price_registry_snapshot"]["currency_status"] == "mixed"
    assert contract["pricing_status"] == "unknown"
    assert contract["hard_cost_cap"] == nil
  end

  test "price changes do not rewrite historical plans or Run snapshots", context do
    _provider = local_provider(context.workspace, "Local structured model", "local-v1")
    _first_price = retrieval_price(context.workspace, "0.01", -4)
    first_simulation = simulation(context, "How might the first priced scenario change behavior?")
    first_plan = Simulations.current_budget_plan(first_simulation)

    _second_price = retrieval_price(context.workspace, "0.02", -2)

    second_simulation =
      simulation(context, "How might the second priced scenario change behavior?")

    second_plan = Simulations.current_budget_plan(second_simulation)

    assert D.equal?(first_plan.hard_cost_cap, D.new("0.08"))
    assert D.equal?(second_plan.hard_cost_cap, D.new("0.16"))
    assert D.equal?(Repo.get!(BudgetPlan, first_plan.id).hard_cost_cap, D.new("0.08"))

    assert {:ok, record} = Simulations.create_quick_run(first_simulation, nil)
    assert record.budget_plan_id == first_plan.id
    assert D.equal?(D.new(record.budget_snapshot["hard_cost_cap"]), D.new("0.08"))
    assert record.budget_snapshot["content_hash"] == first_plan.content_hash
  end

  test "route edits create a new run configuration and lock while a run is active", context do
    first = local_provider(context.workspace, "First local model", "local-v1")
    second = local_provider(context.workspace, "Second local model", "local-v2")
    _price = retrieval_price(context.workspace, "0.01", -2)
    simulation = simulation(context)
    initial = Simulations.current_budget_plan(simulation)

    assert {:ok, configuration} =
             Simulations.configure_run(simulation, nil, %{
               "model_routes" => %{
                 "build" => to_string(first.id),
                 "simulation" => "none",
                 "report" => to_string(second.id)
               }
             })

    assert configuration.budget_plan.id != initial.id
    assert configuration.model_route_plan.resolved_routes["build"]["model"] == "local-v1"
    assert configuration.model_route_plan.resolved_routes["report"]["model"] == "local-v2"

    assert {:ok, record} = Simulations.create_quick_run(simulation, nil)
    assert record.budget_plan_id == configuration.budget_plan.id
    assert record.model_route_plan_id == configuration.model_route_plan.id

    assert {:error, :run_already_active} =
             Simulations.configure_run(simulation, nil, %{
               "model_routes" => %{"report" => to_string(first.id)}
             })
  end

  defp simulation(context, question \\ "How might a bounded budget change participant behavior?") do
    assert {:ok, simulation} =
             Simulations.create_simulation(context.workspace, nil, %{
               "question" => question,
               "blueprint_id" => context.general.id,
               "locale" => "en",
               "execution_mode" => "quick",
               "population_size" => "40",
               "horizon" => "2 rounds",
               "inputs" => %{}
             })

    simulation
  end

  defp local_provider(workspace, name, model) do
    assert {:ok, provider} =
             Runtime.create_provider(%{
               workspace_id: workspace.id,
               name: name,
               kind: "mock",
               model: model,
               enabled: true,
               metadata: %{
                 "capabilities" => %{
                   "structured_generation" => true,
                   "local_execution" => true
                 }
               }
             })

    provider
  end

  defp retrieval_price(workspace, minimum, offset_seconds) do
    assert {:ok, price} =
             PriceRegistry.create_entry(%{
               workspace_id: workspace.id,
               provider: "web_search",
               model: "request",
               currency: "USD",
               input_per_million: "0",
               output_per_million: "0",
               request_minimum: minimum,
               effective_from:
                 DateTime.utc_now()
                 |> DateTime.add(offset_seconds, :second)
                 |> DateTime.truncate(:microsecond),
               operator_override: true,
               metadata: %{"source" => "test"}
             })

    price
  end

  defp model_price(workspace, provider, model, currency, per_million) do
    assert {:ok, price} =
             PriceRegistry.create_entry(%{
               workspace_id: workspace.id,
               provider: provider,
               model: model,
               currency: currency,
               input_per_million: per_million,
               output_per_million: per_million,
               request_minimum: "0",
               effective_from: DateTime.add(DateTime.utc_now(), -2, :second),
               operator_override: true,
               metadata: %{"source" => "test"}
             })

    price
  end

  defp resolved_route(provider, model) do
    %{
      "status" => "resolved",
      "provider" => provider,
      "model" => model,
      "local" => false,
      "route_version" => hash("#{provider}:#{model}")
    }
  end

  defp retrieval_request(index) do
    %{
      "kind" => "retrieval",
      "max_input_tokens" => 0,
      "max_output_tokens" => 0,
      "idempotency_key" => hash("retrieval-#{index}")
    }
  end

  defp hash(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
