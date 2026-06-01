defmodule HydraAgentWeb.AgentStudioLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.{Automations, Budgets, Connectors, Knowledge, Rooms, Runtime}

  test "runs selected agent in sandbox without durable writes", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Studio Agent",
        slug: "studio-agent",
        model_route: %{"default_provider" => "mock"},
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"]
      })

    {:ok, view, html} =
      live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}&agent_id=#{agent.id}")

    assert html =~ "Agent Studio"
    assert has_element?(view, "#agent-studio")

    view
    |> form("form[phx-submit='run-sandbox']",
      studio: %{mode: "sandbox", prompt: "hello studio"}
    )
    |> render_submit()

    html = render(view)
    assert html =~ "mock: hello studio"
    assert html =~ "No durable writes"
    assert Knowledge.list_nodes(workspace.id, type_key: "memory") == []
  end

  test "memory proposal mode writes only a draft memory proposal", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-memory"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Studio Memory Agent",
        slug: "studio-memory-agent",
        model_route: %{"default_provider" => "mock"},
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"]
      })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/control/agents/studio?workspace_id=#{workspace.id}&agent_id=#{agent.id}&mode=memory_proposals"
      )

    view
    |> form("form[phx-submit='run-sandbox']",
      studio: %{mode: "memory_proposals", prompt: "remember this"}
    )
    |> render_submit()

    [proposal] = Knowledge.list_nodes(workspace.id, type_key: "memory")
    assert proposal.status == "draft"
    assert proposal.attributes["proposal_status"] == "pending"
  end

  test "creates a room and sends a shared room message", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-room"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Room Agent",
        slug: "room-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}&agent_id=#{agent.id}")

    view
    |> form("form[phx-submit='create-room']",
      room: %{
        title: "Launch Room",
        slug: "launch-room",
        coordinator_agent_id: agent.id
      }
    )
    |> render_submit()

    [room] = Rooms.list_rooms(workspace.id)
    assert room.title == "Launch Room"

    view
    |> form("form[phx-submit='send-room-message']",
      room_message: %{content: "status please"}
    )
    |> render_submit()

    view
    |> form("form[phx-submit='create-room-binding']",
      binding: %{
        slug: "launch-telegram",
        external_chat_id: "-10099",
        token_env: "TELEGRAM_BOT_TOKEN"
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "status please"
    assert html =~ "mock: status please"
    assert html =~ "/launch-telegram"
    assert html =~ "setWebhook"
    assert html =~ "Telegram Production Setup"
    assert html =~ "Delivery Receipts"
    assert html =~ "Export"

    html =
      view
      |> form("form[phx-change='filter-room-messages']",
        room_filter: %{query: "mock", author_type: "agent"}
      )
      |> render_change()

    assert html =~ "mock: status please"
  end

  test "shows Telegram setup checklist for pending chat capture", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-telegram-wizard"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    agent =
      agent_fixture(workspace, %{
        name: "Telegram Agent",
        slug: "telegram-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, view, _html} =
      live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}&agent_id=#{agent.id}")

    view
    |> form("form[phx-submit='create-room']",
      room: %{
        title: "Telegram Room",
        slug: "telegram-room",
        coordinator_agent_id: agent.id
      }
    )
    |> render_submit()

    html =
      view
      |> form("form[phx-submit='create-room-binding']",
        binding: %{
          slug: "telegram-wizard",
          external_chat_id: "",
          token_env: "DOES_NOT_EXIST_TELEGRAM_TOKEN"
        }
      )
      |> render_submit()

    assert html =~ "Telegram Production Setup"
    assert html =~ "needs attention"
    assert html =~ "env:DOES_NOT_EXIST_TELEGRAM_TOKEN is not set"
    assert html =~ "Secret header is recommended for production"
    assert html =~ "Waiting for first inbound Telegram message"
    assert html =~ "No outbound Telegram delivery confirmed yet"
    assert html =~ "PHX_HOST is not set"
    assert html =~ "No delivery receipts recorded yet"
  end

  test "approves pending room proposals from the studio", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-proposal"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    coordinator =
      agent_fixture(workspace, %{
        name: "Studio Coordinator",
        slug: "studio-coordinator",
        model_route: %{"default_provider" => "mock"}
      })

    reviewer =
      agent_fixture(workspace, %{
        name: "Studio Reviewer",
        slug: "studio-reviewer",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Proposal Room",
        slug: "proposal-room",
        coordinator_agent_id: coordinator.id
      })

    {:ok, _member} =
      Rooms.create_member(room, %{agent_id: reviewer.id, mention_handle: "reviewer"})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/control/agents/studio?workspace_id=#{workspace.id}&agent_id=#{coordinator.id}&room_id=#{room.id}"
      )

    view
    |> form("form[phx-submit='send-room-message']",
      room_message: %{content: "@studio-coordinator @reviewer compare"}
    )
    |> render_submit()

    assert render(view) =~ "agents requested"

    view
    |> element("button[phx-click='approve-room-proposal']", "Approve")
    |> render_click()

    html = render(view)
    assert html =~ "mock: @studio-coordinator @reviewer compare"
    refute html =~ "agents requested"
  end

  test "guided builder creates an agent and policy from the studio", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-builder"})

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-model"
      })

    {:ok, view, _html} = live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}")

    view
    |> form("form[phx-submit='create-builder-agent']",
      builder: %{
        name: "Review Captain",
        preset: "reviewer",
        default_provider: "mock",
        system_prompt: "Review carefully."
      }
    )
    |> render_change()

    assert render(view) =~ "Policy Preview"

    view
    |> form("form[phx-submit='create-builder-agent']",
      builder: %{
        name: "Review Captain",
        preset: "reviewer",
        default_provider: "mock",
        system_prompt: "Review carefully."
      }
    )
    |> render_submit()

    agent = Runtime.get_agent_by_slug(workspace.id, "review-captain")
    assert agent.name == "Review Captain"
    assert render(view) =~ "Created Review Captain"
  end

  test "imports bundled starter agent packs from the studio", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-starter-packs"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Daily OS",
        slug: "daily-os"
      })

    {:ok, view, html} =
      live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}&room_id=#{room.id}")

    assert html =~ "Starter Agent Packs"
    assert html =~ "Daily Chief of Staff"

    view
    |> element(
      "#starter-agent-pack-daily-chief-of-staff button[phx-click='import-starter-pack']",
      "Import"
    )
    |> render_click()

    agent = Runtime.get_agent_by_slug(workspace.id, "daily-chief-of-staff")
    assert agent.name == "Daily Chief of Staff"
    assert agent.capability_profile["task_pack"] == "daily_os"
    assert "telegram" in agent.capability_profile["connector_requirements"]
    assert render(view) =~ "Imported Daily Chief of Staff and added it to Daily OS"

    room = Rooms.get_room!(room.id)
    member = Enum.find(room.members, &(&1.agent_id == agent.id))
    assert member.mention_handle == "chief"
    assert member.response_mode == "coordinator"
  end

  test "daily os setup wizard is idempotent", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-agent-studio-daily-os"})

    {:ok, view, html} = live(conn, ~p"/control/agents/studio?workspace_id=#{workspace.id}")

    assert html =~ "Daily OS Setup"

    view
    |> element("button[phx-click='setup-daily-os']", "Set Up Daily OS")
    |> render_click()

    html = render(view)
    assert html =~ "Daily OS ready"
    assert html =~ "5 imported"
    assert html =~ "8 prepared"
    assert html =~ "20 grants created"
    assert html =~ "10 scheduled"
    assert html =~ "6 budgets created"
    assert html =~ "daily-os-connector-readiness"
    assert html =~ "daily-os-automation-readiness"
    assert html =~ "missing_secret_env"
    assert html =~ "Store the member or organization access token in LINKEDIN_ACCESS_TOKEN"
    assert html =~ "LinkedIn author URN"
    assert html =~ "10 blocked"

    room = Enum.find(Rooms.list_rooms(workspace.id), &(&1.slug == "daily-os"))
    assert room.title == "Daily OS"
    assert length(room.members) == 5
    assert Enum.any?(room.channel_bindings, &(&1.slug == "daily-os-telegram-#{workspace.id}"))

    agents = Runtime.list_agents(workspace.id)
    assert Enum.count(agents, &(&1.capability_profile["task_pack"] == "daily_os")) == 5
    connectors = Connectors.list_accounts(workspace.id)
    assert length(connectors) == 8

    assert connectors
           |> Enum.map(&Connectors.agent_permission_grants/1)
           |> Enum.map(&map_size/1)
           |> Enum.sum() == 18

    assert length(Automations.list_automations(workspace.id)) == 10
    budgets = Budgets.list_budgets(workspace.id)
    assert length(budgets) == 6
    assert Enum.any?(budgets, &(&1.name == "Daily OS Workspace Monthly Token Limit"))
    assert Enum.count(budgets, &(&1.agent_id != nil)) == 5

    view
    |> element("button[phx-click='setup-daily-os']", "Set Up Daily OS")
    |> render_click()

    room = Enum.find(Rooms.list_rooms(workspace.id), &(&1.slug == "daily-os"))
    assert length(room.members) == 5
    assert length(room.channel_bindings) == 1
    assert length(Connectors.list_accounts(workspace.id)) == 8
    assert length(Automations.list_automations(workspace.id)) == 10
    assert length(Budgets.list_budgets(workspace.id)) == 6

    assert Enum.count(
             Runtime.list_agents(workspace.id),
             &(&1.capability_profile["task_pack"] == "daily_os")
           ) == 5

    html = render(view)
    assert html =~ "5 reused"
    assert html =~ "8 reused"
    assert html =~ "20 reused"
    assert html =~ "10 reused"
    assert html =~ "6 reused"
    assert html =~ "daily-os-automation-readiness"
  end
end
