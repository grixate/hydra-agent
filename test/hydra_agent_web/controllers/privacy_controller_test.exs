defmodule HydraAgentWeb.PrivacyControllerTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Runtime

  setup do
    previous = Application.get_env(:hydra_agent, :public_disclosure)

    on_exit(fn -> Application.put_env(:hydra_agent, :public_disclosure, previous) end)

    :ok
  end

  test "shows honest deployment data flow and configured routes", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Pilot", slug: "privacy-pilot"})

    {:ok, _external} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "Hosted model",
        kind: "openai_compatible",
        model: "gpt-test",
        api_key_env: "PILOT_PROVIDER_KEY"
      })

    {:ok, _local} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "Local model",
        kind: "ollama",
        model: "local-test"
      })

    Application.put_env(:hydra_agent, :public_disclosure,
      operator_name: "Hydra Pilot Operator",
      support_email: "support@example.test",
      security_email: "security@example.test",
      privacy_url: "https://example.test/privacy",
      retention_summary: "Pilot data is reviewed every 30 days."
    )

    response =
      conn
      |> get(~p"/settings/privacy?workspace_id=#{workspace.id}&locale=en")
      |> html_response(200)

    assert response =~ "Know what stays here—and what may leave."
    assert response =~ "Hydra Pilot Operator"
    assert response =~ "Hosted model"
    assert response =~ "External provider"
    assert response =~ "Local model"
    assert response =~ "Local to this deployment"
    refute response =~ "Operator notice is incomplete"
  end

  test "missing operator disclosure is visible and Russian copy preserves the contract", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{name: "Пилот", slug: "privacy-pilot-ru"})

    response =
      conn
      |> get(~p"/settings/privacy?workspace_id=#{workspace.id}&locale=ru")
      |> html_response(200)

    assert response =~ "Что остаётся здесь"
    assert response =~ "Уведомление оператора не заполнено"
    assert response =~ "Не опубликовано оператором"
    assert response =~ "Быстрая симуляция не обращается к моделям"
  end
end
