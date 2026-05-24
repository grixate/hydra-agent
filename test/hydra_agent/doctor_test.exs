defmodule HydraAgent.DoctorTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Doctor

  test "status is error when any check errors" do
    assert Doctor.status([%{"status" => "ok"}, %{"status" => "error"}]) == "error"
  end

  test "status is warning when checks warn but do not error" do
    assert Doctor.status([%{"status" => "ok"}, %{"status" => "warning"}]) == "warning"
  end

  test "status is ok when all checks pass" do
    assert Doctor.status([%{"status" => "ok"}]) == "ok"
  end

  test "summarize counts checks by status" do
    assert Doctor.summarize([
             %{"status" => "ok"},
             %{"status" => "ok"},
             %{"status" => "warning"}
           ]) == %{"ok" => 2, "warning" => 1, "total" => 3}
  end
end
