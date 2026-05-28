defmodule HydraAgent.AutomationsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{AgentPack, Automations, Connectors, Runtime}
  alias HydraAgent.Automations.Automation

  test "computes next run time from cron expressions" do
    from = ~U[2026-05-24 10:01:00Z]

    assert %DateTime{} = next_run = Automations.next_run_at("*/15 * * * *", from)
    assert DateTime.compare(next_run, from) == :gt
  end

  test "computes next run time through supported timezone semantics" do
    from = ~U[2026-05-24 10:01:00Z]

    assert %DateTime{} = next_run = Automations.next_run_at("0 11 * * *", from, "Etc/UTC")
    assert next_run == ~U[2026-05-24 11:00:00Z]
  end

  test "returns nil for unsupported timezones" do
    from = ~U[2026-05-24 10:01:00Z]

    assert Automations.next_run_at("0 11 * * *", from, "America/New_York") == nil
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

  test "creates automations from seeded recipes" do
    workspace = workspace_fixture(%{slug: "automation-recipes"})
    agent = agent_fixture(workspace, %{slug: "automation-recipe-agent"})

    assert Enum.any?(Automations.recipes(), &(&1["id"] == "daily_briefing"))

    assert {:ok, automation} =
             Automations.create_from_recipe(workspace.id, "daily_briefing", %{
               "agent_id" => agent.id,
               "room_id" => 123
             })

    assert automation.slug == "daily-briefing"
    assert automation.metadata["recipe_id"] == "daily_briefing"
    assert automation.metadata["permission_preset"] == "approve_writes"
    assert "email" in automation.metadata["required_connectors"]
  end

  test "starter pack automation recipes are available" do
    available_recipe_ids = Automations.recipes() |> Enum.map(& &1["id"]) |> MapSet.new()

    referenced_recipe_ids =
      AgentPack.valid_builtin_packs()
      |> Enum.flat_map(&(&1["automation_recipes"] || []))
      |> MapSet.new()

    assert MapSet.subset?(referenced_recipe_ids, available_recipe_ids)
  end

  test "reports automation connector readiness blockers" do
    workspace = workspace_fixture(%{slug: "automation-readiness"})
    agent = agent_fixture(workspace, %{slug: "automation-readiness-agent"})
    missing_env = "HYDRA_TEST_MISSING_EMAIL_TOKEN_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)

    {:ok, _email} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "email-readiness",
        credential_env: missing_env
      })

    {:ok, _notes} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notes",
        slug: "notes-readiness"
      })

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Ready Check",
        slug: "ready-check",
        cron_expression: "0 9 * * *",
        prompt: "Run readiness check.",
        metadata: %{"required_connectors" => ["email", "notes", "calendar"]}
      })

    readiness = Automations.readiness(automation, Connectors.list_accounts(workspace.id))

    assert readiness["status"] == "blocked"
    assert readiness["required_connectors"] == ["calendar", "email", "notes"]
    assert Enum.any?(readiness["blockers"], &(&1["reason"] == "connector_missing"))

    assert Enum.any?(readiness["blockers"], fn blocker ->
             blocker["provider"] == "email" and
               Enum.any?(blocker["findings"], &(&1["reason"] == "missing_secret_env"))
           end)
  end

  test "reports ready when required connectors are configured" do
    workspace = workspace_fixture(%{slug: "automation-readiness-ready"})
    agent = agent_fixture(workspace, %{slug: "automation-readiness-ready-agent"})

    {:ok, _notes} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notes",
        slug: "notes-ready"
      })

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Ready Automation",
        slug: "ready-automation",
        cron_expression: "0 9 * * *",
        prompt: "Run.",
        metadata: %{"required_connectors" => ["notes"]}
      })

    readiness = Automations.readiness(automation, Connectors.list_accounts(workspace.id))

    assert readiness["status"] == "ready"
    assert readiness["blockers"] == []
    assert readiness["warnings"] == []
  end

  test "fails closed before running when required connectors are blocked" do
    workspace = workspace_fixture(%{slug: "automation-readiness-fail-closed"})
    agent = agent_fixture(workspace, %{slug: "automation-readiness-fail-agent"})

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Blocked Automation",
        slug: "blocked-automation",
        cron_expression: "0 9 * * *",
        prompt: "Run.",
        metadata: %{"required_connectors" => ["email"]}
      })

    assert {:ok, blocked} = Automations.run_automation(automation)
    assert blocked.last_error["reason"] == "automation_connector_readiness_blocked"
    assert blocked.last_error["readiness"]["status"] == "blocked"
    assert blocked.last_run_at
    assert Runtime.list_runs(workspace.id) == []
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

  test "rejects unsupported timezone declarations" do
    changeset =
      Automation.changeset(%Automation{}, %{
        workspace_id: 1,
        agent_id: 1,
        name: "Local Morning",
        slug: "local-morning",
        cron_expression: "0 9 * * *",
        timezone: "America/New_York",
        prompt: "Run."
      })

    refute changeset.valid?

    assert {"is not supported by the configured timezone database: utc_only_time_zone_database",
            _meta} = changeset.errors[:timezone]
  end
end
