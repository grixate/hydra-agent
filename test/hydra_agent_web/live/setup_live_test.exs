defmodule HydraAgentWeb.SetupLiveTest do
  use HydraAgentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HydraAgent.Runtime

  test "renders first-run setup when no workspaces exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ "Set up Hydra"
    assert html =~ "Create workspace"
  end

  test "creates the first workspace from the setup form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> form("#setup-form",
      setup: %{
        "workspace_name" => "Ops",
        "workspace_slug" => "ops-live",
        "provider_kind" => "mock",
        "provider_model" => "mock-chat",
        "provider_base_url" => "",
        "provider_api_key_env" => "",
        "seed_skills" => "true",
        "install_starter_agents" => "true"
      }
    )
    |> render_submit()

    workspace = Runtime.list_workspaces() |> Enum.find(&(&1.slug == "ops-live"))
    assert workspace
    assert_redirected(view, ~p"/control?workspace_id=#{workspace.id}")
  end

  test "points configured instances back to control", %{conn: conn} do
    {:ok, _workspace} = Runtime.create_workspace(%{name: "Ops", slug: "ops-existing"})

    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ "Hydra is already configured"
    assert html =~ "Open control"
  end
end
