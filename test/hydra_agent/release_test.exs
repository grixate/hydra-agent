defmodule HydraAgent.ReleaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias HydraAgent.Release

  test "smoke succeeds and prints the doctor report for ok status" do
    output =
      capture_io(fn ->
        assert :ok =
                 Release.smoke(
                   start_app?: false,
                   doctor: fn opts ->
                     assert opts == []
                     %{"status" => "ok", "checks" => [], "summary" => %{"total" => 0}}
                   end
                 )
      end)

    assert Jason.decode!(output)["data"]["status"] == "ok"
  end

  test "smoke passes workspace id to the doctor report" do
    output =
      capture_io(fn ->
        assert :ok =
                 Release.smoke(
                   start_app?: false,
                   workspace_id: "workspace-1",
                   doctor: fn opts ->
                     assert opts == [workspace_id: "workspace-1"]
                     %{"status" => "ok", "checks" => [], "summary" => %{"total" => 0}}
                   end
                 )
      end)

    assert Jason.decode!(output)["data"]["status"] == "ok"
  end

  test "smoke fails when doctor reports errors" do
    assert_raise RuntimeError, "Hydra production smoke failed: doctor reported errors", fn ->
      capture_io(fn ->
        Release.smoke(
          start_app?: false,
          doctor: fn _opts ->
            %{"status" => "error", "checks" => [], "summary" => %{"total" => 0}}
          end
        )
      end)
    end
  end

  test "smoke can fail on warnings for stricter deployment gates" do
    assert_raise RuntimeError, "Hydra production smoke failed: doctor reported warnings", fn ->
      capture_io(fn ->
        Release.smoke(
          start_app?: false,
          fail_on_warning?: true,
          doctor: fn _opts ->
            %{"status" => "warning", "checks" => [], "summary" => %{"total" => 0}}
          end
        )
      end)
    end
  end
end
