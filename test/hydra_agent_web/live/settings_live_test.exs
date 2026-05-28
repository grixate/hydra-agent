defmodule HydraAgentWeb.SettingsLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime

  test "falls back from malformed workspace params", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-settings-malformed-param"})

    {:ok, view, html} = live(conn, ~p"/control/settings?workspace_id=not-an-id")

    assert html =~ "Settings"
    assert render(view) =~ workspace.name
  end

  test "renders settings posture for providers credentials and policies", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-settings-live"})

    {:ok, pool} =
      Runtime.create_credential_pool(%{
        workspace_id: workspace.id,
        name: "Provider Secrets",
        env_vars: ["OPENAI_API_KEY"]
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        credential_pool_id: pool.id,
        name: "OpenAI",
        kind: "openai_compatible",
        model: "gpt-4.1-mini",
        api_key_env: "OPENAI_API_KEY"
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        allowed_tools: ["file_read"],
        side_effect_classes: ["read_only"],
        requires_approval: false
      })

    {:ok, view, html} = live(conn, ~p"/control/settings?workspace_id=#{workspace.id}")

    assert html =~ "Settings"
    assert has_element?(view, "#settings")
    html = render(view)
    assert html =~ "OpenAI"
    assert html =~ "Provider Secrets"
    assert html =~ "file_read"
    assert html =~ "Permission Presets"
    assert html =~ "Approve Writes"
    assert html =~ "Token Spend Guardrails"
    assert html =~ "web_research"
  end

  test "creates token budget guardrails from settings", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-settings-budget"})
    agent = agent_fixture(workspace, %{name: "Spend Agent", slug: "spend-agent"})

    {:ok, view, _html} = live(conn, ~p"/control/settings?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#settings-budget-form", %{
        budget: %{
          name: "Daily Agent Spend",
          agent_id: agent.id,
          category: "chat",
          period: "daily",
          token_limit: "25000"
        }
      })
      |> render_submit()

    assert html =~ "Budget guardrail created"
    assert html =~ "Daily Agent Spend"
    assert html =~ "Spend Agent"
    assert html =~ "chat / daily"
    assert html =~ "tokens 0 / 25000"
  end

  test "shows budget validation errors without creating guardrails", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-settings-budget-invalid"})

    {:ok, view, _html} = live(conn, ~p"/control/settings?workspace_id=#{workspace.id}")

    html =
      view
      |> form("#settings-budget-form", %{
        budget: %{
          name: "",
          category: "chat",
          period: "daily",
          token_limit: "0"
        }
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert html =~ "must be greater than"
    refute html =~ "Budget guardrail created"
  end
end
