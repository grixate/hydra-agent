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

  test "advances strictly beyond an exact cron boundary" do
    from = ~U[2026-07-11 10:00:00.000000Z]

    assert Automations.next_run_at("*/5 * * * *", from) == ~U[2026-07-11 10:05:00Z]
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

  test "rejects agent associations outside the automation workspace on create and update" do
    workspace = workspace_fixture(%{slug: "automation-agent-scope"})
    other_workspace = workspace_fixture(%{slug: "other-automation-agent-scope"})
    agent = agent_fixture(workspace, %{slug: "automation-agent-scope-owner"})
    foreign_agent = agent_fixture(other_workspace, %{slug: "automation-agent-scope-foreign"})

    attrs = %{
      workspace_id: workspace.id,
      agent_id: foreign_agent.id,
      name: "Cross-workspace automation",
      slug: "cross-workspace-automation",
      cron_expression: "0 9 * * *",
      prompt: "This must not be created."
    }

    assert {:error, changeset} = Automations.create_automation(attrs)
    assert %{agent_id: ["must belong to the same workspace"]} = errors_on(changeset)
    assert Automations.list_automations(workspace.id) == []
    assert Automations.list_automations(other_workspace.id) == []

    assert {:ok, automation} =
             Automations.create_automation(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               name: "Scoped automation",
               slug: "scoped-automation",
               cron_expression: "0 9 * * *",
               prompt: "Stay inside the workspace."
             })

    assert {:error, changeset} =
             Automations.update_automation(automation, %{agent_id: foreign_agent.id})

    assert %{agent_id: ["must belong to the same workspace"]} = errors_on(changeset)

    assert {:error, changeset} =
             Automations.update_automation(automation, %{workspace_id: other_workspace.id})

    assert %{agent_id: ["must belong to the same workspace"]} = errors_on(changeset)

    persisted = Repo.get!(Automation, automation.id)
    assert persisted.workspace_id == workspace.id
    assert persisted.agent_id == agent.id
  end

  test "racing dispatchers execute a scheduled occurrence at most once" do
    workspace = workspace_fixture(%{slug: "automation-occurrence-race"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        slug: "automation-occurrence-race-agent",
        model_route: %{"default_provider" => "mock"}
      })

    scheduled_for = ~U[2026-07-11 10:00:00.000000Z]
    observed_at = ~U[2026-07-11 10:00:30.000000Z]

    assert {:ok, automation} =
             Automations.create_automation(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               name: "Race-safe automation",
               slug: "race-safe-automation",
               cron_expression: "0 10 * * *",
               prompt: "Produce one response.",
               next_run_at: scheduled_for
             })

    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Automations.run_due_automations(observed_at))
        end)
      end

    Enum.each(tasks, fn _task ->
      assert_receive {:ready, pid}
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      send(pid, :go)
    end)

    results = tasks |> Enum.map(&Task.await(&1, 10_000)) |> List.flatten()
    assert Enum.count(results, &match?({:ok, %Automation{}}, &1)) == 1

    assert [run] = Runtime.list_runs(workspace.id)
    assert [_conversation] = Runtime.list_conversations(workspace.id)

    assert [execution] =
             Automations.list_executions(workspace.id, automation_id: automation.id)

    assert execution.status == "completed"
    assert execution.trigger == "scheduled"
    assert execution.scheduled_for == scheduled_for
    assert execution.run_id == run.id
    assert run.metadata["automation_execution_id"] == execution.id
    assert run.metadata["scheduled_for"] == DateTime.to_iso8601(scheduled_for)

    persisted = Repo.get!(Automation, automation.id)
    assert persisted.next_run_at == ~U[2026-07-12 10:00:00.000000Z]
  end

  test "a claimed occurrence is not retried after a dispatcher crash" do
    workspace = workspace_fixture(%{slug: "automation-occurrence-crash"})
    agent = agent_fixture(workspace, %{slug: "automation-occurrence-crash-agent"})
    scheduled_for = ~U[2026-07-11 10:00:00.000000Z]
    observed_at = ~U[2026-07-11 10:17:00.000000Z]

    assert {:ok, automation} =
             Automations.create_automation(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               name: "Crash-safe automation",
               slug: "crash-safe-automation",
               cron_expression: "*/5 * * * *",
               prompt: "Do not duplicate this occurrence.",
               next_run_at: scheduled_for
             })

    assert {:ok, claimed, advanced} =
             Automations.claim_due_automation(automation, observed_at)

    assert claimed.status == "claimed"
    assert claimed.scheduled_for == scheduled_for
    assert claimed.next_scheduled_for == ~U[2026-07-11 10:05:00.000000Z]
    assert advanced.next_run_at == claimed.next_scheduled_for

    assert {:skip, :execution_in_flight} =
             Automations.claim_due_automation(automation, observed_at)

    assert Automations.run_due_automations(observed_at) == []
    assert Automations.run_due_automations(observed_at) == []
    assert Runtime.list_runs(workspace.id) == []
    assert Runtime.list_conversations(workspace.id) == []

    assert [persisted_claim] =
             Automations.list_executions(workspace.id, automation_id: automation.id)

    assert persisted_claim.id == claimed.id
    assert persisted_claim.status == "claimed"
    assert persisted_claim.run_id == nil
    assert persisted_claim.metadata["claim_policy"] == "at_most_once"
    assert Repo.get!(Automation, automation.id).next_run_at == claimed.next_scheduled_for
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

    assert [%{status: "blocked", result: %{"executed" => false}}] =
             Automations.list_executions(workspace.id, automation_id: automation.id)
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
