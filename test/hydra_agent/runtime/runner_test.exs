defmodule HydraAgent.Runtime.RunnerTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Runtime.Run
  alias HydraAgent.Runtime.Runner

  test "does not execute canceled runs" do
    assert {:error, %{"reason" => "run_not_runnable", "status" => "canceled"}} =
             Runner.execute_next_step(%Run{id: 1, status: "canceled"})
  end

  test "does not execute parallel batches for paused runs" do
    assert {:error, %{"reason" => "run_not_runnable", "status" => "paused"}} =
             Runner.execute_parallel_safe_batch(%Run{id: 1, status: "paused"})
  end
end
