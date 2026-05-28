defmodule HydraAgentWeb.DoctorControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Automations, Connectors, Doctor, Rooms}

  test "global doctor reports browser worker configuration problems", %{conn: conn} do
    original = Application.get_env(:hydra_agent, :browser_worker_url)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:hydra_agent, :browser_worker_url)
      else
        Application.put_env(:hydra_agent, :browser_worker_url, original)
      end
    end)

    Application.put_env(:hydra_agent, :browser_worker_url, "not-a-url")

    conn = get(conn, ~p"/api/v1/doctor")

    assert %{"data" => %{"checks" => checks}} = json_response(conn, 200)

    assert %{"status" => "warning", "summary" => "Browser worker URL is invalid"} =
             check_by_name(checks, "browser_worker")
  end

  test "workspace doctor reports Telegram, connector, automation, and MCP readiness", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-doctor-readiness"})
    agent = agent_fixture(workspace, %{name: "Ops Agent", slug: "ops-doctor-agent"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Ops Room",
        slug: "ops-room-doctor"
      })

    {:ok, _binding} =
      Rooms.create_channel_binding(room, %{
        provider: "telegram",
        slug: "ops-room-doctor-telegram",
        external_chat_id: "pending:ops-room-doctor-telegram",
        token_env: "DOCTOR_MISSING_TELEGRAM_TOKEN",
        secret_env: "DOCTOR_MISSING_TELEGRAM_SECRET",
        config: %{"capture_chat_id" => true}
      })

    {:ok, _email} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "email",
        slug: "doctor-email",
        display_name: "Doctor Email"
      })

    {:ok, _linkedin} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "linkedin",
        slug: "doctor-linkedin",
        display_name: "Doctor LinkedIn",
        credential_env: "DOCTOR_MISSING_LINKEDIN_TOKEN"
      })

    {:ok, _automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Doctor Content Draft",
        slug: "doctor-content-draft",
        cron_expression: "0 10 * * 1",
        prompt: "Draft social content.",
        metadata: %{"required_connectors" => ["notes", "x", "linkedin"]}
      })

    conn = get(conn, ~p"/api/v1/workspaces/#{workspace.id}/doctor")

    assert %{"data" => %{"status" => "warning", "checks" => checks}} = json_response(conn, 200)

    assert %{"status" => "warning", "metadata" => %{"findings" => telegram_findings}} =
             check_by_name(checks, "telegram")

    assert Enum.any?(telegram_findings, &(&1["reason"] == "chat_id_capture_pending"))
    assert Enum.any?(telegram_findings, &(&1["reason"] == "token_env_not_configured"))

    assert %{"status" => "warning", "metadata" => %{"findings" => connector_findings}} =
             check_by_name(checks, "connectors")

    assert Enum.any?(connector_findings, &(&1["reason"] == "credential_env_missing"))
    assert Enum.any?(connector_findings, &(&1["reason"] == "required_config_missing"))

    assert %{"status" => "warning", "metadata" => %{"findings" => automation_findings}} =
             check_by_name(checks, "automations")

    assert Enum.any?(
             automation_findings,
             &(&1["reason"] == "required_connectors_missing" and "x" in &1["providers"])
           )

    assert Enum.any?(
             automation_findings,
             &(&1["reason"] == "connector_readiness_blocked" and
                 &1["readiness"]["status"] == "blocked")
           )

    assert %{"status" => "ok"} = check_by_name(checks, "mcp")
  end

  test "workspace doctor reports ready connector and automation surfaces" do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-doctor-ready"})
    agent = agent_fixture(workspace, %{name: "Ready Agent", slug: "ready-agent"})

    {:ok, _notes} =
      Connectors.create_account(%{
        workspace_id: workspace.id,
        provider: "notes",
        slug: "ready-notes",
        display_name: "Ready Notes"
      })

    {:ok, _automation} =
      Automations.create_automation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        name: "Ready Notes Automation",
        slug: "ready-notes-automation",
        cron_expression: "0 8 * * *",
        prompt: "Summarize notes.",
        metadata: %{"required_connectors" => ["notes"]}
      })

    report =
      Doctor.run(
        workspace_id: workspace.id,
        agent_pack_glob: "test/fixtures/no-agent-packs/*.json"
      )

    checks = report["checks"]

    assert %{"status" => "ok"} = check_by_name(checks, "connectors")
    assert %{"status" => "ok"} = check_by_name(checks, "automations")
  end

  defp check_by_name(checks, name), do: Enum.find(checks, &(&1["name"] == name))
end
