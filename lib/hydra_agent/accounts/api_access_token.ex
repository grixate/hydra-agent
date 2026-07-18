defmodule HydraAgent.Accounts.ApiAccessToken do
  use Ecto.Schema
  import Ecto.Changeset

  @permissions ~w(read write)

  schema "api_access_tokens" do
    field :name, :string
    field :token_prefix, :string
    field :token_hash, :binary, redact: true
    field :permissions, {:array, :string}, default: ["read"]
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :created_by, HydraAgent.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :name,
      :token_prefix,
      :token_hash,
      :permissions,
      :expires_at,
      :last_used_at,
      :revoked_at,
      :workspace_id,
      :created_by_id
    ])
    |> validate_required([:name, :token_prefix, :token_hash, :permissions])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_length(:token_prefix, min: 8, max: 20)
    |> validate_subset(:permissions, @permissions)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_id)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:token_prefix)
  end
end
