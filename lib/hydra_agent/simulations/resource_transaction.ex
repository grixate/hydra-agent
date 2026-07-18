defmodule HydraAgent.Simulations.ResourceTransaction do
  use Ecto.Schema
  import Ecto.Changeset

  @operations ~w(mint burn transfer reserve release consume replenish adjust)
  @phases ~w(before_actions actions after_actions transitions)

  schema "resource_transactions" do
    field :sequence, :integer
    field :round, :integer
    field :phase, :string
    field :resource_id, :string
    field :source_account, :string
    field :destination_account, :string
    field :amount, :decimal
    field :operation, :string
    field :source_ref, :string
    field :tags, {:array, :string}, default: []
    field :resulting_balances, :map, default: %{}
    field :idempotency_key, :string

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :run, HydraAgent.Runtime.Run
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def operations, do: @operations

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :simulation_run_record_id,
      :sequence,
      :round,
      :phase,
      :resource_id,
      :source_account,
      :destination_account,
      :amount,
      :operation,
      :source_ref,
      :tags,
      :resulting_balances,
      :idempotency_key
    ])
    |> validate_required([
      :workspace_id,
      :run_id,
      :simulation_run_record_id,
      :sequence,
      :round,
      :phase,
      :resource_id,
      :amount,
      :operation,
      :resulting_balances,
      :idempotency_key
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:round, greater_than_or_equal_to: 0)
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> validate_inclusion(:operation, @operations)
    |> validate_inclusion(:phase, @phases)
    |> validate_accounts()
    |> validate_length(:resource_id, min: 1, max: 120)
    |> validate_length(:idempotency_key, min: 16, max: 160)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> unique_constraint([:run_id, :sequence])
    |> unique_constraint([:run_id, :idempotency_key])
    |> check_constraint(:operation, name: :resource_transactions_operation_check)
  end

  defp validate_accounts(changeset) do
    operation = get_field(changeset, :operation)
    source = get_field(changeset, :source_account)
    destination = get_field(changeset, :destination_account)

    valid? =
      case operation do
        operation when operation in ~w(transfer reserve release) ->
          is_binary(source) and is_binary(destination) and source != destination

        operation when operation in ~w(mint replenish) ->
          is_nil(source) and is_binary(destination)

        operation when operation in ~w(burn consume) ->
          is_binary(source) and is_nil(destination)

        "adjust" ->
          (is_binary(source) and is_nil(destination)) or
            (is_nil(source) and is_binary(destination))

        _operation ->
          true
      end

    if valid?, do: changeset, else: add_error(changeset, :operation, "has invalid accounts")
  end
end
