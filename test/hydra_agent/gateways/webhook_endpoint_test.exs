defmodule HydraAgent.Gateways.WebhookEndpointTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Gateways.WebhookEndpoint

  test "validates env-backed webhook endpoint declarations" do
    changeset =
      WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
        workspace_id: 1,
        agent_id: 1,
        name: "Deploy Review",
        slug: "deploy-review",
        target_type: "agent_chat",
        token_env: "HYDRA_WEBHOOK_TOKEN"
      })

    assert changeset.valid?
  end

  test "requires agent-backed targets to name an agent" do
    changeset =
      WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
        workspace_id: 1,
        name: "Run trigger",
        slug: "run-trigger",
        target_type: "run_create",
        token_env: "HYDRA_WEBHOOK_TOKEN"
      })

    refute changeset.valid?
    assert {"is required for run_create", _meta} = changeset.errors[:agent_id]
  end

  test "rejects non-env-style token refs" do
    changeset =
      WebhookEndpoint.changeset(%WebhookEndpoint{}, %{
        workspace_id: 1,
        agent_id: 1,
        name: "Bad",
        slug: "bad",
        target_type: "agent_chat",
        token_env: "plain-secret"
      })

    refute changeset.valid?
    assert {"must name an environment variable", _meta} = changeset.errors[:token_env]
  end
end
