defmodule HydraAgent.Runtime.CredentialPoolItem do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active cooldown exhausted disabled)
  @sources ~w(env vault keyring manual)

  schema "credential_pool_items" do
    field :label, :string
    field :source, :string, default: "env"
    field :env_var, :string
    field :status, :string, default: "active"
    field :priority, :integer, default: 0
    field :request_count, :integer, default: 0
    field :failure_count, :integer, default: 0
    field :cooldown_until, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :credential_pool, HydraAgent.Runtime.CredentialPool

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :credential_pool_id,
      :label,
      :source,
      :env_var,
      :status,
      :priority,
      :request_count,
      :failure_count,
      :cooldown_until,
      :last_used_at,
      :last_error,
      :metadata
    ])
    |> put_default_label()
    |> validate_required([:credential_pool_id, :label, :source, :env_var, :status])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:env_var, ~r/^[A-Z][A-Z0-9_]*$/,
      message: "must name an environment variable"
    )
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:request_count, greater_than_or_equal_to: 0)
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:credential_pool)
    |> unique_constraint(:env_var, name: :credential_pool_items_credential_pool_id_env_var_index)
  end

  def statuses, do: @statuses

  defp put_default_label(changeset) do
    case get_field(changeset, :label) do
      value when is_binary(value) and value != "" -> changeset
      _value -> put_change(changeset, :label, get_field(changeset, :env_var) || "credential")
    end
  end
end
