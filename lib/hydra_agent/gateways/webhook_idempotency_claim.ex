defmodule HydraAgent.Gateways.WebhookIdempotencyClaim do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(processing completed)

  schema "webhook_idempotency_claims" do
    field :idempotency_key, :string
    field :request_sha256, :string
    field :status, :string, default: "processing"
    field :response_status, :integer
    field :response_body, :map
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :webhook_endpoint, HydraAgent.Gateways.WebhookEndpoint
    belongs_to :run, HydraAgent.Runtime.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :workspace_id,
      :webhook_endpoint_id,
      :run_id,
      :idempotency_key,
      :request_sha256,
      :status,
      :response_status,
      :response_body,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :webhook_endpoint_id,
      :idempotency_key,
      :request_sha256,
      :status
    ])
    |> validate_length(:idempotency_key, min: 1, max: 128)
    |> validate_format(:request_sha256, ~r/^[0-9a-f]{64}$/)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:webhook_endpoint)
    |> assoc_constraint(:run)
    |> unique_constraint([:webhook_endpoint_id, :idempotency_key],
      name: :webhook_idempotency_claims_endpoint_key_index
    )
    |> check_constraint(:status, name: :webhook_idempotency_claims_status_check)
    |> check_constraint(:status, name: :webhook_idempotency_claims_completion_check)
  end
end
