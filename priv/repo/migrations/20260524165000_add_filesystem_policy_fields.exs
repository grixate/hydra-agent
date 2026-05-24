defmodule HydraAgent.Repo.Migrations.AddFilesystemPolicyFields do
  use Ecto.Migration

  def change do
    alter table(:tool_policies) do
      add :filesystem_allowlist, {:array, :string}, null: false, default: []
      add :filesystem_denylist, {:array, :string}, null: false, default: []
    end
  end
end
