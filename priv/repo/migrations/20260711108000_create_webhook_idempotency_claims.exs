defmodule HydraAgent.Repo.Migrations.CreateWebhookIdempotencyClaims do
  use Ecto.Migration

  def change do
    create table(:webhook_idempotency_claims) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false

      add :webhook_endpoint_id, references(:webhook_endpoints, on_delete: :delete_all),
        null: false

      add :run_id, references(:runs, on_delete: :nilify_all)
      add :idempotency_key, :string, size: 128, null: false
      add :request_sha256, :string, size: 64, null: false
      add :status, :string, null: false, default: "processing"
      add :response_status, :integer
      add :response_body, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :webhook_idempotency_claims,
             [:webhook_endpoint_id, :idempotency_key],
             name: :webhook_idempotency_claims_endpoint_key_index
           )

    create index(:webhook_idempotency_claims, [:workspace_id, :inserted_at])
    create index(:webhook_idempotency_claims, [:run_id])

    create constraint(:webhook_idempotency_claims, :webhook_idempotency_claims_status_check,
             check: "status IN ('processing', 'completed')"
           )

    create constraint(
             :webhook_idempotency_claims,
             :webhook_idempotency_claims_completion_check,
             check:
               "(status = 'processing' AND response_status IS NULL AND response_body IS NULL AND completed_at IS NULL) OR " <>
                 "(status = 'completed' AND response_status IS NOT NULL AND response_body IS NOT NULL AND completed_at IS NOT NULL)"
           )
  end
end
