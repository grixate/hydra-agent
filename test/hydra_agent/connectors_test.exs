defmodule HydraAgent.ConnectorsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Connectors, Knowledge}

  setup do
    workspace = workspace_fixture(%{slug: "connectors-v4"})
    {:ok, workspace: workspace}
  end

  test "creates connector accounts with provider capabilities", %{workspace: workspace} do
    assert {:ok, account} =
             Connectors.create_account(%{
               workspace_id: workspace.id,
               provider: "email",
               slug: "primary-email",
               display_name: "Primary Email",
               credential_env: "EMAIL_ACCESS_TOKEN"
             })

    assert "email.draft" in account.capabilities
    assert account.credential_env == "EMAIL_ACCESS_TOKEN"
  end

  test "provider specs expose setup requirements" do
    specs = Connectors.provider_specs()

    assert %{setup: %{credential_env: "X_ACCESS_TOKEN", scopes: scopes}} =
             Enum.find(specs, &(&1.provider == "x"))

    assert "tweet.write" in scopes

    assert %{setup: %{credential_env: "LINKEDIN_ACCESS_TOKEN", config_fields: fields}} =
             Enum.find(specs, &(&1.provider == "linkedin"))

    assert "author_urn" in fields

    assert %{setup: %{credential_env: "TELEGRAM_BOT_TOKEN", config_fields: telegram_fields}} =
             Enum.find(specs, &(&1.provider == "telegram"))

    assert "chat_id" in telegram_fields
  end

  test "provider setup guide explains env refs and config fields" do
    guide = Connectors.provider_setup_guide("linkedin")

    assert guide["credential_env"] == "LINKEDIN_ACCESS_TOKEN"
    assert "author_urn" in guide["config_fields"]
    assert guide["config_help"]["author_urn"] =~ "LinkedIn author URN"
    assert Enum.any?(guide["steps"], &String.contains?(&1, "w_member_social"))
  end

  test "read and draft actions execute immediately", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "draft-email",
        display_name: "Draft Email"
      })

    assert {:ok, action} =
             Connectors.request_action(account, %{
               action: "draft",
               input: %{"to" => "team@example.com", "body" => "Hello"}
             })

    assert action.status == "completed"
    assert action.side_effect_class == "read_only"
    assert action.result["mode"] == "draft"
  end

  test "external write actions require approval before execution", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "send-email",
        display_name: "Send Email"
      })

    assert {:ok, action} =
             Connectors.request_action(account, %{
               action: "send",
               input: %{"to" => "team@example.com", "body" => "Ship it"}
             })

    assert action.status == "awaiting_approval"
    assert action.side_effect_class == "external_delivery"

    assert {:ok, approved} = Connectors.approve_action(action, %{"approved_by" => "operator"})
    assert approved.status == "completed"
    assert approved.approved_by == "operator"
    assert approved.result["mode"] == "approved_recorded"
  end

  test "agent connector writes fail closed until explicitly granted", %{workspace: workspace} do
    agent = agent_fixture(workspace, %{slug: "connector-agent"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "x",
        slug: "agent-x-social",
        display_name: "Agent X Social"
      })

    assert {:error, %{"reason" => "connector_permission_required"}} =
             Connectors.request_action(account, %{
               agent_id: agent.id,
               action: "publish_post",
               input: %{"text" => "Drafted by an agent."}
             })

    assert {:ok, account} =
             Connectors.grant_agent_permission(account, %{
               agent_id: agent.id,
               action: "publish_post",
               mode: "approval_required",
               granted_by: "operator"
             })

    assert get_in(account.metadata, ["agent_grants", to_string(agent.id), "actions"]) == [
             "publish_post"
           ]

    assert {:ok, action} =
             Connectors.request_action(account, %{
               agent_id: agent.id,
               action: "publish_post",
               input: %{"text" => "Drafted by an agent."}
             })

    assert action.status == "awaiting_approval"
  end

  test "connector permission grants are workspace scoped", %{workspace: workspace} do
    other_workspace = workspace_fixture(%{slug: "connector-grant-other-workspace"})
    other_agent = agent_fixture(other_workspace, %{slug: "foreign-agent"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "x",
        slug: "workspace-scoped-x",
        display_name: "Workspace Scoped X"
      })

    assert {:error, %{"reason" => "connector_agent_not_in_workspace"}} =
             Connectors.grant_agent_permission(account, %{
               agent_id: other_agent.id,
               action: "publish_post"
             })
  end

  test "trusted connector grants are required before agent writes can bypass approval", %{
    workspace: workspace
  } do
    agent = agent_fixture(workspace, %{slug: "trusted-connector-agent"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "x",
        slug: "trusted-x-social",
        display_name: "Trusted X Social"
      })

    assert {:ok, account} =
             Connectors.grant_agent_permission(account, %{
               agent_id: agent.id,
               action: "publish_post",
               mode: "trusted"
             })

    assert {:ok, action} =
             Connectors.request_action(account, %{
               agent_id: agent.id,
               action: "publish_post",
               approval_mode: "trusted",
               input: %{"text" => "Trusted publish path."}
             })

    assert action.status == "completed"
    assert action.result["mode"] == "approved_recorded"
  end

  test "workspace scoped getters reject cross-workspace connector ids", %{workspace: workspace} do
    other_workspace = workspace_fixture(%{slug: "connectors-other-workspace"})

    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "scoped-email",
        display_name: "Scoped Email"
      })

    {:ok, action} =
      Connectors.request_action(account, %{
        action: "send",
        input: %{"to" => "team@example.com", "body" => "Ship it"}
      })

    assert Connectors.get_account_for_workspace!(workspace.id, account.id).id == account.id
    assert Connectors.get_action_for_workspace!(workspace.id, action.id).id == action.id

    assert_raise Ecto.NoResultsError, fn ->
      Connectors.get_account_for_workspace!(other_workspace.id, account.id)
    end

    assert_raise Ecto.NoResultsError, fn ->
      Connectors.get_action_for_workspace!(other_workspace.id, action.id)
    end
  end

  test "unconfigured read connectors return safe stubs", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "youtube",
        slug: "youtube-research",
        display_name: "YouTube"
      })

    assert {:ok, action} =
             Connectors.request_action(account, %{
               action: "search",
               input: %{"query" => "hydra agents"}
             })

    assert action.status == "completed"
    assert action.result["mode"] == "research_stub"
    assert action.result["configured"] == false
  end

  test "social post actions are approval gated and safely recorded without credentials", %{
    workspace: workspace
  } do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "x",
        slug: "x-social",
        display_name: "X Social"
      })

    assert {:ok, action} =
             Connectors.request_action(account, %{
               action: "publish_post",
               input: %{"text" => "Hydra drafted this."}
             })

    assert action.status == "awaiting_approval"
    assert action.side_effect_class == "external_delivery"

    assert {:ok, completed} = Connectors.approve_action(action)
    assert completed.status == "completed"
    assert completed.result["mode"] == "approved_recorded"
    assert completed.result["delivered"] == false
  end

  test "linkedin health checks required author configuration", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "linkedin",
        slug: "linkedin-social",
        display_name: "LinkedIn Social"
      })

    assert {:ok, checked} = Connectors.health_check(account)
    assert checked.last_health["status"] == "unhealthy"
    assert checked.last_error["reason"] == "missing_required_connector_config"
    assert checked.last_error["fields"] == ["author_urn"]

    readiness = Connectors.setup_readiness(account)
    assert readiness["status"] == "needs_attention"
    assert readiness["missing_required_config"] == ["author_urn"]
    assert readiness["setup_guide"]["config_help"]["author_urn"] =~ "LinkedIn author URN"
  end

  test "can reject pending connector actions", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notion",
        slug: "notion-notes",
        display_name: "Notion"
      })

    {:ok, action} =
      Connectors.request_action(account, %{
        action: "append_note",
        input: %{"title" => "Research"}
      })

    assert {:ok, rejected} = Connectors.reject_action(action, %{"reason" => "not now"})
    assert rejected.status == "rejected"
    assert rejected.last_error["reason"] == "rejected"
  end

  test "approved notes connector actions write workspace notes", %{workspace: workspace} do
    {:ok, account} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notes",
        slug: "workspace-notes",
        display_name: "Workspace Notes"
      })

    {:ok, action} =
      Connectors.request_action(account, %{
        action: "append",
        input: %{"title" => "Research Note", "content" => "Hydra remembers this."}
      })

    assert action.status == "awaiting_approval"

    assert {:ok, completed} = Connectors.approve_action(action)
    assert completed.status == "completed"
    assert completed.result["mode"] == "workspace_note"

    [node] = Knowledge.list_nodes(workspace.id, type_key: "note")
    assert node.title == "Research Note"
    assert node.body == "Hydra remembers this."
  end
end
