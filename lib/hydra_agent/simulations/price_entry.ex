defmodule HydraAgent.Simulations.PriceEntry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_price_entries" do
    field :provider, :string
    field :model, :string
    field :currency, :string, default: "USD"
    field :input_per_million, :decimal
    field :cached_input_per_million, :decimal
    field :output_per_million, :decimal
    field :request_minimum, :decimal
    field :effective_from, :utc_datetime_usec
    field :operator_override, :boolean, default: false
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :workspace_id,
      :provider,
      :model,
      :currency,
      :input_per_million,
      :cached_input_per_million,
      :output_per_million,
      :request_minimum,
      :effective_from,
      :operator_override,
      :metadata
    ])
    |> validate_required([:provider, :model, :currency, :effective_from, :operator_override])
    |> validate_length(:provider, min: 1, max: 120)
    |> validate_length(:model, min: 1, max: 180)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_nonnegative(:input_per_million)
    |> validate_nonnegative(:cached_input_per_million)
    |> validate_nonnegative(:output_per_million)
    |> validate_nonnegative(:request_minimum)
    |> foreign_key_constraint(:workspace_id)
    |> check_constraint(:currency, name: :simulation_price_entries_currency_check)
    |> check_constraint(:input_per_million,
      name: :simulation_price_entries_nonnegative_check
    )
    |> unique_constraint([:provider, :model, :effective_from],
      name: :simulation_price_entries_global_identity_index
    )
    |> unique_constraint([:workspace_id, :provider, :model, :effective_from],
      name: :simulation_price_entries_workspace_identity_index
    )
  end

  defp validate_nonnegative(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_number(changeset, field, greater_than_or_equal_to: 0)
    end
  end
end
