defmodule HydraAgentWeb.AutomationLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.{Automations, Connectors}
  alias HydraAgent.Runtime

  test "renders empty automations page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/automations")

    assert html =~ "Automations"
    assert html =~ "No workspaces yet."
  end

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/automations?workspace_id=not-an-id")

    assert html =~ "Automations"
    assert render(view) =~ workspace.name
  end

  test "renders workspace automations with agents, schedule, and error state", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automations"})
    agent = agent_fixture(workspace, %{name: "Runtime Steward", slug: "runtime-steward-auto"})

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Morning Runtime Review",
        slug: "morning-runtime-review",
        cron_expression: "0 9 * * *",
        timezone: "Etc/UTC",
        prompt: "Review overnight failures.",
        last_error: %{
          "reason" => "previous_provider_error",
          "message" => "Mock provider timed out",
          "provider" => "mock"
        },
        metadata: %{"last_conversation_id" => 123, "last_assistant_turn_id" => 456}
      })

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Automation: Morning Runtime Review",
        channel: "automation",
        metadata: %{
          "automation_id" => automation.id,
          "triggered_by" => "schedule",
          "result" => "failed"
        }
      })

    tool_policy_fixture(workspace, %{
      agent_id: agent.id,
      allowed_tools: ["knowledge_read"],
      side_effect_classes: ["read_only"],
      requires_approval: true
    })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert has_element?(view, "#automations")
    assert has_element?(view, "#control-shell-nav")
    assert has_element?(view, "#automation-card-#{automation.id}")

    html = render(view)
    assert html =~ "Morning Runtime Review"
    assert html =~ "active / Runtime Steward"
    assert html =~ "0 9 * * *"
    assert html =~ "Review overnight failures."
    assert html =~ "previous_provider_error"
    assert html =~ "Failure Detail"
    assert html =~ "Mock provider timed out"
    assert html =~ "provider"
    assert html =~ "Last Output"
    assert html =~ "conversation 123 / assistant turn 456"
    assert html =~ "Schedule Preview"
    assert html =~ "Safety Policy"
    assert html =~ "1 policies / approval gated / read_only"
    assert html =~ "Connector Readiness"
    assert html =~ "requires none"
    assert html =~ "ready"
    assert html =~ "Recent Runs"
    assert html =~ "Automation: Morning Runtime Review"
    assert html =~ "conversation #{conversation.id} / automation"
    assert html =~ "triggered_by"
    assert has_element?(view, "#automation-history-item-#{automation.id}-#{conversation.id}")
  end

  test "creates automations from the inline schedule form", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-create"})
    agent = agent_fixture(workspace, %{name: "Schedule Agent", slug: "schedule-agent"})

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    preview_html =
      render_change(
        form(view, "#automation-form", %{
          automation: %{
            agent_id: agent.id,
            name: "Daily Queue Review",
            slug: "daily-queue-review",
            status: "active",
            cron_expression: "0 9 * * *",
            timezone: "Etc/UTC",
            prompt: "Summarize overnight queue pressure."
          }
        })
      )

    assert preview_html =~ "Schedule Preview"
    assert preview_html =~ "Next five matching runs"
    assert preview_html =~ "1."
    assert preview_html =~ "5."
    assert preview_html =~ "UTC"

    view
    |> form("#automation-form", %{
      automation: %{
        agent_id: agent.id,
        name: "Daily Queue Review",
        slug: "daily-queue-review",
        status: "active",
        cron_expression: "0 9 * * *",
        timezone: "Etc/UTC",
        prompt: "Summarize overnight queue pressure."
      }
    })
    |> render_submit()

    [automation] = Automations.list_automations(workspace.id)
    assert automation.name == "Daily Queue Review"
    assert automation.agent_id == agent.id
    assert automation.next_run_at
    assert has_element?(view, "#automation-card-#{automation.id}")
  end

  test "creates automations from recipe catalog", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-recipes"})
    agent = agent_fixture(workspace, %{name: "Chief of Staff", slug: "chief-of-staff-auto"})

    {:ok, view, html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert html =~ "Ready-made automations"
    assert has_element?(view, "#automation-recipe-daily_briefing")

    html =
      view
      |> form("#automation-recipe-daily_briefing form",
        recipe: %{recipe_id: "daily_briefing", agent_id: agent.id}
      )
      |> render_submit()

    assert html =~ "Recipe automation created"

    [automation] = Automations.list_automations(workspace.id)
    assert automation.slug == "daily-briefing"
    assert automation.metadata["recipe_id"] == "daily_briefing"

    html = render(view)
    assert html =~ "Connector Readiness"
    assert html =~ "requires calendar, email, notes"
    assert html =~ "email: connector account is missing"
  end

  test "shows validation errors and invalid cron preview", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-validation"})
    agent = agent_fixture(workspace)

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#automation-form", %{
        automation: %{
          agent_id: agent.id,
          name: "Broken",
          slug: "broken automation",
          status: "active",
          cron_expression: "not cron",
          timezone: "Etc/UTC",
          prompt: ""
        }
      })
      |> render_submit()

    assert html =~ "invalid cron"
    assert html =~ "has invalid format"
    assert html =~ "can&#39;t be blank"
    assert Automations.list_automations(workspace.id) == []
  end

  test "rejects unsupported timezones instead of silently treating them as UTC", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-timezone"})
    agent = agent_fixture(workspace)

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#automation-form", %{
        automation: %{
          agent_id: agent.id,
          name: "Local Morning",
          slug: "local-morning",
          status: "active",
          cron_expression: "0 9 * * *",
          timezone: "America/New_York",
          prompt: "Run in local time."
        }
      })
      |> render_submit()

    assert html =~ "unsupported timezone"
    assert html =~ "is not supported by the configured timezone database"
    assert Automations.list_automations(workspace.id) == []
  end

  test "edits automations from the inline schedule form", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-edit"})
    agent = agent_fixture(workspace)

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Old Schedule",
        slug: "old-schedule",
        cron_expression: "0 8 * * *",
        prompt: "Old prompt."
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    view |> element("#automation-edit-#{automation.id}") |> render_click()

    view
    |> form("#automation-form", %{
      automation: %{
        agent_id: agent.id,
        name: "Updated Schedule",
        slug: "updated-schedule",
        status: "paused",
        cron_expression: "*/20 * * * *",
        timezone: "Etc/UTC",
        prompt: "Updated prompt."
      }
    })
    |> render_submit()

    updated = Automations.get_automation!(automation.id)
    assert updated.name == "Updated Schedule"
    assert updated.slug == "updated-schedule"
    assert updated.status == "paused"
    assert updated.cron_expression == "*/20 * * * *"
    assert updated.prompt == "Updated prompt."
  end

  test "filters automations by status", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-filter"})
    agent = agent_fixture(workspace)

    {:ok, active} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Active Automation",
        slug: "active-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run active schedule."
      })

    {:ok, paused} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Paused Automation",
        slug: "paused-automation",
        status: "paused",
        cron_expression: "0 * * * *",
        prompt: "Run paused schedule."
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert has_element?(view, "#automation-card-#{active.id}")
    assert has_element?(view, "#automation-card-#{paused.id}")

    view
    |> form("#automations-filter-form", %{status: "paused"})
    |> render_change()

    assert_patch(view, ~p"/control/automations?workspace_id=#{workspace.id}&status=paused")
    refute has_element?(view, "#automation-card-#{active.id}")
    assert has_element?(view, "#automation-card-#{paused.id}")
  end

  test "filters and clears automations that need attention", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-attention"})
    agent = agent_fixture(workspace)

    {:ok, healthy} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Healthy Automation",
        slug: "healthy-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run healthy schedule."
      })

    {:ok, failed} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Failed Automation",
        slug: "failed-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run failed schedule.",
        last_error: %{"reason" => "provider_timeout"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert render(view) =~ "provider_timeout"
    assert has_element?(view, "#automation-clear-error-#{failed.id}")

    view
    |> form("#automations-filter-form", %{status: "needs_attention"})
    |> render_change()

    assert_patch(
      view,
      ~p"/control/automations?workspace_id=#{workspace.id}&status=needs_attention"
    )

    refute has_element?(view, "#automation-card-#{healthy.id}")
    assert has_element?(view, "#automation-card-#{failed.id}")

    view |> element("#automation-clear-error-#{failed.id}") |> render_click()

    assert Automations.get_automation!(failed.id).last_error == %{}
    refute has_element?(view, "#automation-card-#{failed.id}")
    assert render(view) =~ "No automations match this filter."
  end

  test "filters automations with connector readiness blockers", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-readiness-filter"})
    agent = agent_fixture(workspace)

    {:ok, healthy} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Healthy Automation",
        slug: "healthy-readiness-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run healthy schedule."
      })

    {:ok, blocked} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Blocked Automation",
        slug: "blocked-readiness-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run blocked schedule.",
        metadata: %{"required_connectors" => ["email"]}
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert render(view) =~ "email: connector account is missing"

    view
    |> form("#automations-filter-form", %{status: "needs_attention"})
    |> render_change()

    assert_patch(
      view,
      ~p"/control/automations?workspace_id=#{workspace.id}&status=needs_attention"
    )

    refute has_element?(view, "#automation-card-#{healthy.id}")
    assert has_element?(view, "#automation-card-#{blocked.id}")
  end

  test "shows connector setup blockers when accounts exist but credentials are missing", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-readiness-ui"})
    agent = agent_fixture(workspace)
    missing_env = "HYDRA_TEST_UI_EMAIL_TOKEN_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)

    {:ok, _account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "email-readiness-ui",
        credential_env: missing_env
      })

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Email Automation",
        slug: "email-readiness-automation",
        cron_expression: "*/15 * * * *",
        prompt: "Run email schedule.",
        metadata: %{"required_connectors" => ["email"]}
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    assert has_element?(view, "#automation-readiness-#{automation.id}")
    html = render(view)
    assert html =~ "Connector Readiness"
    assert html =~ "blocked"
    assert html =~ "missing_secret_env"
  end

  test "automation lifecycle buttons update status", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-actions"})
    agent = agent_fixture(workspace)

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Action Automation",
        slug: "action-automation",
        cron_expression: "*/10 * * * *",
        prompt: "Exercise automation actions."
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    view |> element("#automation-pause-#{automation.id}") |> render_click()
    assert Automations.get_automation!(automation.id).status == "paused"

    view |> element("#automation-resume-#{automation.id}") |> render_click()
    assert Automations.get_automation!(automation.id).status == "active"

    view |> element("#automation-archive-#{automation.id}") |> render_click()
    assert Automations.get_automation!(automation.id).status == "archived"
  end

  test "trigger button runs automation through the configured agent", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-run"})

    agent =
      agent_fixture(workspace, %{
        name: "Automation Agent",
        slug: "automation-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Trigger Automation",
        slug: "trigger-automation",
        cron_expression: "*/30 * * * *",
        prompt: "Summarize the queue."
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    view |> element("#automation-run-#{automation.id}") |> render_click()

    triggered = Automations.get_automation!(automation.id)
    assert triggered.last_run_at
    assert triggered.last_error == %{}
    assert triggered.metadata["last_run_id"]
    assert triggered.metadata["last_conversation_id"]
    assert triggered.metadata["last_assistant_turn_id"]

    [run] =
      workspace.id
      |> Runtime.list_runs()
      |> Enum.filter(&(&1.metadata["automation_id"] == automation.id))

    assert run.status == "completed"
    assert run.supervisor_agent_id == agent.id
    assert run.result["conversation_id"] == triggered.metadata["last_conversation_id"]
    assert run.metadata["automation_slug"] == "trigger-automation"
    assert run.metadata["conversation_id"] == triggered.metadata["last_conversation_id"]

    html = render(view)
    assert html =~ "Recent Runs"
    assert html =~ "Runtime Runs"
    assert html =~ "Execution Analytics"
    assert html =~ "runs 1"
    assert html =~ "completed 1"
    assert html =~ "failed 0"
    assert html =~ "Automation: Trigger Automation"
    assert html =~ "run #{run.id} / conversation"
    assert has_element?(view, "#automation-run-history-item-#{automation.id}-#{run.id}")
    assert has_element?(view, ~s|a[href="/control/runs/#{run.id}"]|, "Open run")
  end

  test "failed automation triggers still create auditable runs", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-automation-run-failure"})

    agent =
      agent_fixture(workspace, %{
        name: "Broken Automation Agent",
        slug: "broken-automation-agent",
        model_route: %{"default_provider" => "missing-provider"}
      })

    {:ok, automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Failing Automation",
        slug: "failing-automation",
        cron_expression: "*/30 * * * *",
        prompt: "This should fail provider routing."
      })

    {:ok, view, _html} = live(conn, ~p"/control/automations?workspace_id=#{workspace.id}")

    view |> element("#automation-run-#{automation.id}") |> render_click()

    triggered = Automations.get_automation!(automation.id)
    assert triggered.last_run_at
    assert triggered.last_error["reason"] == "no_enabled_provider"
    assert triggered.metadata["last_run_id"]

    [run] =
      workspace.id
      |> Runtime.list_runs()
      |> Enum.filter(&(&1.metadata["automation_id"] == automation.id))

    assert run.status == "failed"
    assert run.result["error"]["reason"] == "no_enabled_provider"

    html = render(view)
    assert html =~ "Failure Detail"
    assert html =~ "no_enabled_provider"
    assert html =~ "Runtime Runs"
    assert html =~ "Execution Analytics"
    assert html =~ "runs 1"
    assert html =~ "completed 0"
    assert html =~ "failed 1"
    assert has_element?(view, "#automation-run-history-item-#{automation.id}-#{run.id}")
    assert has_element?(view, ~s|a[href="/control/runs/#{run.id}"]|, "Open run")
  end
end
