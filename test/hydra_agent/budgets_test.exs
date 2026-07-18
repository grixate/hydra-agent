defmodule HydraAgent.BudgetsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Budgets
  alias HydraAgent.Budgets.Budget
  alias HydraAgent.Repo
  alias HydraAgent.Usage
  alias HydraAgent.Usage.Record

  test "usage summaries aggregate every matching row in PostgreSQL" do
    workspace = workspace_fixture(%{slug: "usage-aggregate-all"})
    inserted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..10_005, fn _index ->
        %{
          workspace_id: workspace.id,
          category: "chat",
          status: "ok",
          total_tokens: 1,
          inserted_at: inserted_at
        }
      end)

    {_count, nil} = Repo.insert_all(Record, rows)

    assert %{
             "records" => 10_005,
             "total_tokens" => 10_005,
             "by_category" => %{"chat" => 10_005}
           } = Usage.summarize(workspace.id)
  end

  test "cost budgets account for priced and unpriced provider usage" do
    workspace = workspace_fixture(%{slug: "cost-budget-accounting"})

    {:ok, budget} =
      Budgets.create_budget(%{
        workspace_id: workspace.id,
        name: "Provider cost",
        period: "total",
        cost_limit: Decimal.new("10.00")
      })

    {:ok, _record} =
      Usage.create_record(%{
        workspace_id: workspace.id,
        category: "chat",
        status: "ok",
        total_tokens: 100,
        estimated_cost: Decimal.new("8.00")
      })

    status = Budgets.budget_status(budget)
    assert status["status"] == "warning"
    assert status["used_cost"] == Decimal.new("8.00")
    assert_in_delta status["cost_ratio"], 0.8, 0.0001

    {:ok, _unpriced} =
      Usage.create_record(%{
        workspace_id: workspace.id,
        category: "chat",
        status: "ok",
        total_tokens: 1
      })

    status = Budgets.budget_status(Repo.get!(Budget, budget.id))
    assert status["status"] == "exceeded"
    assert status["unpriced_records"] == 1
  end

  test "concurrent reservations cannot spend the same remaining token budget" do
    workspace = workspace_fixture(%{slug: "atomic-budget-reservation"})

    {:ok, _budget} =
      Budgets.create_budget(%{
        workspace_id: workspace.id,
        name: "Chat tokens",
        period: "total",
        token_limit: 100
      })

    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              Budgets.reserve_provider_call(workspace.id,
                category: "chat",
                requested_tokens: 70
              )
          end
        end)
      end

    Enum.each(tasks, fn _task ->
      assert_receive {:ready, pid}
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      send(pid, :go)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, %Record{status: "reserved"}}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{"reason" => "budget_reservation_exceeds_limit"}}, &1)
           ) == 1

    assert Usage.summarize(workspace.id)["total_tokens"] == 70
  end

  test "cost budgets fail closed when a call has no estimate" do
    workspace = workspace_fixture(%{slug: "cost-budget-requires-estimate"})

    {:ok, _budget} =
      Budgets.create_budget(%{
        workspace_id: workspace.id,
        name: "Known spend only",
        period: "total",
        cost_limit: Decimal.new("5.00")
      })

    assert {:error, %{"reason" => "cost_estimate_required"}} =
             Budgets.reserve_provider_call(workspace.id,
               category: "chat",
               requested_tokens: 20
             )

    assert Usage.summarize(workspace.id)["records"] == 0
  end
end
