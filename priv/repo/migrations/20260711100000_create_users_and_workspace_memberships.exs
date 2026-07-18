defmodule HydraAgent.Repo.Migrations.CreateUsersAndWorkspaceMemberships do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :display_name, :string, null: false
      add :password_hash, :text, null: false
      add :global_role, :string, null: false, default: "member"
      add :status, :string, null: false, default: "active"
      add :last_signed_in_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create constraint(:users, :users_global_role_check,
             check: "global_role IN ('member', 'system_admin')"
           )

    create constraint(:users, :users_status_check, check: "status IN ('active', 'suspended')")

    create table(:workspace_memberships) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id, :role])

    create constraint(:workspace_memberships, :workspace_memberships_role_check,
             check: "role IN ('viewer', 'researcher', 'admin', 'owner')"
           )
  end
end
