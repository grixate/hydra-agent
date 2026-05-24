defmodule HydraAgent.AutomationsTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Automations
  alias HydraAgent.Automations.Automation

  test "computes next run time from cron expressions" do
    from = ~U[2026-05-24 10:01:00Z]

    assert %DateTime{} = next_run = Automations.next_run_at("*/15 * * * *", from)
    assert DateTime.compare(next_run, from) == :gt
  end

  test "validates automation declarations" do
    changeset =
      Automation.changeset(%Automation{}, %{
        workspace_id: 1,
        agent_id: 1,
        name: "Morning review",
        slug: "morning-review",
        cron_expression: "0 9 * * *",
        prompt: "Review overnight failures."
      })

    assert changeset.valid?
  end

  test "rejects invalid cron expressions" do
    changeset =
      Automation.changeset(%Automation{}, %{
        workspace_id: 1,
        agent_id: 1,
        name: "Broken",
        slug: "broken",
        cron_expression: "not cron",
        prompt: "Run."
      })

    refute changeset.valid?
    assert {"is invalid: Can't parse not as minute.", _meta} = changeset.errors[:cron_expression]
  end
end
