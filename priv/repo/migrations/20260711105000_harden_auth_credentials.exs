defmodule HydraAgent.Repo.Migrations.HardenAuthCredentials do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :session_version, :integer, null: false, default: 1
      add :password_changed_at, :utc_datetime_usec
    end

    create constraint(:users, :users_positive_session_version, check: "session_version > 0")

    create table(:api_access_tokens) do
      add :name, :string, null: false
      add :token_prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :permissions, {:array, :string}, null: false, default: ["read"]
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_access_tokens, [:token_hash])
    create unique_index(:api_access_tokens, [:token_prefix])
    create index(:api_access_tokens, [:workspace_id])
    create index(:api_access_tokens, [:expires_at])

    create constraint(:api_access_tokens, :api_access_tokens_valid_permissions,
             check:
               "cardinality(permissions) > 0 AND permissions <@ ARRAY['read', 'write']::varchar[]"
           )
  end
end
