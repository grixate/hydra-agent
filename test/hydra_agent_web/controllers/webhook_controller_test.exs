defmodule HydraAgentWeb.WebhookControllerTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.DataCase, only: [errors_on: 1]
  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Gateways, Runtime}

  setup do
    previous = System.get_env("HYDRA_WEBHOOK_TEST_SECRET")
    previous_api_token = System.get_env("HYDRA_GATEWAY_API_TOKEN")
    previous_api_auth = Application.get_env(:hydra_agent, :api_auth)
    System.put_env("HYDRA_WEBHOOK_TEST_SECRET", "webhook-test-secret")
    System.put_env("HYDRA_GATEWAY_API_TOKEN", "different-global-api-token")

    Application.put_env(:hydra_agent, :api_auth,
      enabled?: true,
      token_env: "HYDRA_GATEWAY_API_TOKEN"
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("HYDRA_WEBHOOK_TEST_SECRET", previous),
        else: System.delete_env("HYDRA_WEBHOOK_TEST_SECRET")

      if previous_api_token,
        do: System.put_env("HYDRA_GATEWAY_API_TOKEN", previous_api_token),
        else: System.delete_env("HYDRA_GATEWAY_API_TOKEN")

      if previous_api_auth,
        do: Application.put_env(:hydra_agent, :api_auth, previous_api_auth),
        else: Application.delete_env(:hydra_agent, :api_auth)
    end)

    :ok
  end

  test "webhook slugs are globally routable and agents stay in their workspace" do
    first_workspace = workspace_fixture(%{slug: "webhook-first"})
    second_workspace = workspace_fixture(%{slug: "webhook-second"})
    first_agent = agent_fixture(first_workspace, %{slug: "webhook-first-agent"})
    second_agent = agent_fixture(second_workspace, %{slug: "webhook-second-agent"})

    assert {:error, foreign_changeset} =
             Gateways.create_webhook(%{
               workspace_id: first_workspace.id,
               agent_id: second_agent.id,
               name: "Foreign agent",
               slug: "foreign-agent-hook",
               target_type: "run_create",
               token_env: "HYDRA_WEBHOOK_TEST_SECRET"
             })

    assert "must belong to the same workspace" in errors_on(foreign_changeset).agent_id

    assert {:ok, _webhook} =
             Gateways.create_webhook(%{
               workspace_id: first_workspace.id,
               agent_id: first_agent.id,
               name: "Shared route",
               slug: "globally-routed-hook",
               target_type: "run_create",
               token_env: "HYDRA_WEBHOOK_TEST_SECRET"
             })

    assert {:error, duplicate_changeset} =
             Gateways.create_webhook(%{
               workspace_id: second_workspace.id,
               agent_id: second_agent.id,
               name: "Duplicate route",
               slug: "globally-routed-hook",
               target_type: "run_create",
               token_env: "HYDRA_WEBHOOK_TEST_SECRET"
             })

    assert "has already been taken" in errors_on(duplicate_changeset).slug
  end

  test "authenticated webhook dispatch creates one workspace-scoped run", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "webhook-dispatch"})
    agent = agent_fixture(workspace, %{slug: "webhook-dispatch-agent"})

    assert {:ok, webhook} =
             Gateways.create_webhook(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               name: "Run intake",
               slug: "run-intake-hook",
               target_type: "run_create",
               token_env: "HYDRA_WEBHOOK_TEST_SECRET"
             })

    unauthorized =
      post(conn, "/api/v1/webhooks/#{webhook.slug}", %{
        "title" => "Should not run",
        "goal" => "Rejected payload"
      })

    assert %{"errors" => %{"reason" => "missing_bearer_token"}} =
             json_response(unauthorized, 401)

    accepted =
      build_conn()
      |> put_req_header("authorization", "Bearer webhook-test-secret")
      |> put_req_header("idempotency-key", "launch-signal-001")
      |> post("/api/v1/webhooks/#{webhook.slug}", %{
        "title" => "Review launch signal",
        "goal" => "Inspect the latest launch evidence"
      })

    assert %{
             "data" => %{
               "id" => webhook_id,
               "workspace_id" => workspace_id,
               "run_id" => run_id,
               "status" => "accepted"
             }
           } =
             json_response(accepted, 200)

    assert webhook_id == webhook.id
    assert workspace_id == workspace.id
    assert get_resp_header(accepted, "idempotency-replayed") == ["false"]

    [run] = Runtime.list_runs(workspace.id)
    assert run.id == run_id
    assert run.title == "Review launch signal"
    assert run.supervisor_agent_id == agent.id
    assert run.metadata["webhook_endpoint_id"] == webhook.id

    claim = Gateways.get_webhook_idempotency_claim(webhook.id, "launch-signal-001")
    assert claim.workspace_id == workspace.id
    assert claim.run_id == run.id
    assert claim.status == "completed"
    assert claim.response_status == 200
    assert claim.completed_at
    assert claim.request_sha256 =~ ~r/^[0-9a-f]{64}$/
  end

  test "same key and canonical request replays the original response without another run", %{
    conn: conn
  } do
    workspace = workspace_fixture(%{slug: "webhook-replay"})
    agent = agent_fixture(workspace, %{slug: "webhook-replay-agent"})
    webhook = webhook_fixture(workspace, agent, "webhook-replay-hook")

    first_payload = %{
      "title" => "Replay-safe request",
      "goal" => "Process this once",
      "context" => %{"region" => "EU", "priority" => 2}
    }

    second_payload = %{
      "context" => %{"priority" => 2, "region" => "EU"},
      "goal" => "Process this once",
      "title" => "Replay-safe request"
    }

    first = post_webhook(conn, webhook, "client-retry-42", first_payload)
    replay = post_webhook(build_conn(), webhook, "client-retry-42", second_payload)

    assert first_body = json_response(first, 200)
    assert json_response(replay, 200) == first_body
    assert get_resp_header(first, "idempotency-replayed") == ["false"]
    assert get_resp_header(replay, "idempotency-replayed") == ["true"]

    assert [run] = Runtime.list_runs(workspace.id)
    assert run.id == first_body["data"]["run_id"]
    assert length(Gateways.list_webhook_idempotency_claims(workspace.id)) == 1
  end

  test "same key with a materially different request returns conflict", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "webhook-conflict"})
    agent = agent_fixture(workspace, %{slug: "webhook-conflict-agent"})
    webhook = webhook_fixture(workspace, agent, "webhook-conflict-hook")

    first =
      post_webhook(conn, webhook, "conflicting-retry", %{
        "title" => "Original",
        "goal" => "Run the original request"
      })

    assert %{"data" => %{"run_id" => original_run_id}} = json_response(first, 200)

    conflict =
      post_webhook(build_conn(), webhook, "conflicting-retry", %{
        "title" => "Changed",
        "goal" => "Run a different request"
      })

    assert %{
             "errors" => %{
               "code" => "idempotency_conflict",
               "detail" => "Idempotency-Key was already used with a different request"
             }
           } = json_response(conflict, 409)

    assert [run] = Runtime.list_runs(workspace.id)
    assert run.id == original_run_id
    assert length(Gateways.list_webhook_idempotency_claims(workspace.id)) == 1
  end

  test "concurrent retries converge on one durable run and one replay" do
    workspace = workspace_fixture(%{slug: "webhook-concurrent"})
    agent = agent_fixture(workspace, %{slug: "webhook-concurrent-agent"})
    webhook = webhook_fixture(workspace, agent, "webhook-concurrent-hook")
    payload = %{"title" => "Concurrent retry", "goal" => "Create exactly one run"}

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          Gateways.dispatch_idempotent_run(webhook, payload, "simultaneous-retry")
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.sort(Enum.map(results, fn {:ok, _body, 200, replayed?} -> replayed? end)) ==
             [false, true]

    assert [_run] = Runtime.list_runs(workspace.id)
    assert [_claim] = Gateways.list_webhook_idempotency_claims(workspace.id)
  end

  test "the same key is independent across endpoints and workspaces", %{conn: conn} do
    first_workspace = workspace_fixture(%{slug: "webhook-scope-first"})
    second_workspace = workspace_fixture(%{slug: "webhook-scope-second"})
    first_agent = agent_fixture(first_workspace, %{slug: "webhook-scope-first-agent"})
    second_agent = agent_fixture(second_workspace, %{slug: "webhook-scope-second-agent"})

    first_webhook = webhook_fixture(first_workspace, first_agent, "scope-first-hook")
    sibling_webhook = webhook_fixture(first_workspace, first_agent, "scope-sibling-hook")
    second_webhook = webhook_fixture(second_workspace, second_agent, "scope-second-hook")
    payload = %{"title" => "Scoped retry", "goal" => "Create one run per endpoint"}

    assert post_webhook(conn, first_webhook, "shared-client-key", payload).status == 200

    assert post_webhook(build_conn(), sibling_webhook, "shared-client-key", payload).status ==
             200

    assert post_webhook(build_conn(), second_webhook, "shared-client-key", payload).status ==
             200

    assert length(Runtime.list_runs(first_workspace.id)) == 2
    assert length(Runtime.list_runs(second_workspace.id)) == 1
    assert length(Gateways.list_webhook_idempotency_claims(first_workspace.id)) == 2
    assert length(Gateways.list_webhook_idempotency_claims(second_workspace.id)) == 1
  end

  test "run webhooks reject missing, malformed, and oversized idempotency keys", %{conn: conn} do
    workspace = workspace_fixture(%{slug: "webhook-key-validation"})
    agent = agent_fixture(workspace, %{slug: "webhook-key-validation-agent"})
    webhook = webhook_fixture(workspace, agent, "key-validation-hook")
    payload = %{"title" => "Must not run", "goal" => "Reject invalid retry identity"}

    missing =
      conn
      |> put_req_header("authorization", "Bearer webhook-test-secret")
      |> post("/api/v1/webhooks/#{webhook.slug}", payload)

    assert %{"errors" => %{"code" => "idempotency_key_required"}} =
             json_response(missing, 400)

    malformed = post_webhook(build_conn(), webhook, "contains spaces", payload)
    assert %{"errors" => %{"code" => "invalid_idempotency_key"}} = json_response(malformed, 400)

    oversized = post_webhook(build_conn(), webhook, String.duplicate("a", 129), payload)
    assert %{"errors" => %{"code" => "invalid_idempotency_key"}} = json_response(oversized, 400)

    assert Runtime.list_runs(workspace.id) == []
    assert Gateways.list_webhook_idempotency_claims(workspace.id) == []
  end

  defp webhook_fixture(workspace, agent, slug) do
    assert {:ok, webhook} =
             Gateways.create_webhook(%{
               workspace_id: workspace.id,
               agent_id: agent.id,
               name: "Run intake #{slug}",
               slug: slug,
               target_type: "run_create",
               token_env: "HYDRA_WEBHOOK_TEST_SECRET"
             })

    webhook
  end

  defp post_webhook(conn, webhook, idempotency_key, payload) do
    conn
    |> put_req_header("authorization", "Bearer webhook-test-secret")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post("/api/v1/webhooks/#{webhook.slug}", payload)
  end
end
