defmodule HydraAgent.Repo.Migrations.MakeWebhookSlugsGlobal do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:webhook_endpoints, [:workspace_id, :slug])
    drop_if_exists index(:webhook_endpoints, [:slug])
    create unique_index(:webhook_endpoints, [:slug])
  end

  def down do
    drop_if_exists unique_index(:webhook_endpoints, [:slug])
    create index(:webhook_endpoints, [:slug])
    create unique_index(:webhook_endpoints, [:workspace_id, :slug])
  end
end
