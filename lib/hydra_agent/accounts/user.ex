defmodule HydraAgent.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @global_roles ~w(member system_admin)
  @statuses ~w(active suspended)

  schema "users" do
    field :email, :string
    field :display_name, :string
    field :password_hash, :string, redact: true
    field :global_role, :string, default: "member"
    field :status, :string, default: "active"
    field :last_signed_in_at, :utc_datetime_usec
    field :session_version, :integer, default: 1
    field :password_changed_at, :utc_datetime_usec

    has_many :workspace_memberships, HydraAgent.Accounts.WorkspaceMembership
    has_many :workspaces, through: [:workspace_memberships, :workspace]

    has_many :owned_simulation_blueprints, HydraAgent.Simulations.Blueprint,
      foreign_key: :owner_user_id

    has_many :owned_simulations, HydraAgent.Simulations.Simulation, foreign_key: :owner_user_id

    has_many :created_simulation_versions, HydraAgent.Simulations.SimulationVersion,
      foreign_key: :created_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :display_name,
      :password_hash,
      :global_role,
      :status,
      :last_signed_in_at,
      :session_version,
      :password_changed_at
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :display_name, :password_hash, :global_role, :status])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_length(:display_name, min: 2, max: 80)
    |> validate_inclusion(:global_role, @global_roles)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:session_version, greater_than: 0)
    |> unique_constraint(:email)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
