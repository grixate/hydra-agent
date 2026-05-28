defmodule HydraAgentWeb.EvalControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Evals

  test "benchmark endpoint returns workspace benchmark report", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "eval-controller-benchmark"})

    {:ok, _suite} =
      Evals.create_suite(%{
        workspace_id: workspace.id,
        name: "Safety Benchmark",
        slug: "safety-benchmark-api",
        metadata: %{"benchmark_category" => "safety"}
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/evals/benchmark")

    assert %{
             "data" => %{
               "workspace_id" => workspace_id,
               "suite_count" => 1,
               "run_count" => 0,
               "categories" => %{"safety" => %{"suite_count" => 1}},
               "suites" => [%{"suite_slug" => "safety-benchmark-api", "category" => "safety"}]
             }
           } = json_response(conn, 200)

    assert workspace_id == workspace.id
  end

  test "seed benchmark endpoint creates standard benchmark suites", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "eval-controller-benchmark-seed"})

    conn = post(conn, ~p"/api/v1/workspaces/#{workspace.id}/evals/benchmarks/seed")

    assert suites = json_response(conn, 200)["data"]
    assert length(suites) == 6
    assert Enum.all?(suites, &(length(&1["cases"]) == 2))

    categories =
      suites
      |> Enum.map(&get_in(&1, ["metadata", "benchmark_category"]))
      |> Enum.sort()

    assert categories == ~w(cost latency memory orchestration recovery safety)

    benchmark_conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/evals/benchmark")
    assert json_response(benchmark_conn, 200)["data"]["suite_count"] == 6
  end
end
