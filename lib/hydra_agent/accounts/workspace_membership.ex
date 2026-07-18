defmodule HydraAgent.Accounts.WorkspaceMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(viewer researcher admin owner)

  schema "workspace_memberships" do
    field :role, :string, default: "viewer"

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :user, HydraAgent.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:user)
    |> unique_constraint([:workspace_id, :user_id])
  end
end
