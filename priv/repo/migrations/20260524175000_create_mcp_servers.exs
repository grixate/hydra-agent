defmodule HydraAgent.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  def change do
    create table(:mcp_servers) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "inactive"
      add :transport, :string, null: false
      add :trust_level, :string, null: false, default: "sandboxed"
      add :config, :map, null: false, default: %{}
      add :env_refs, {:array, :string}, null: false, default: []
      add :include_tools, {:array, :string}, null: false, default: []
      add :exclude_tools, {:array, :string}, null: false, default: []
      add :resource_access, :boolean, null: false, default: false
      add :prompt_access, :boolean, null: false, default: false
      add :timeout_ms, :integer, null: false, default: 30_000
      add :approval_sensitive, :boolean, null: false, default: true
      add :health_status, :string, null: false, default: "unknown"
      add :last_checked_at, :utc_datetime_usec
      add :last_error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_servers, [:workspace_id, :slug])
    create index(:mcp_servers, [:workspace_id, :status])
    create index(:mcp_servers, [:workspace_id, :health_status])
  end
end
