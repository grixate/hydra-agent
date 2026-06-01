defmodule HydraAgent.Repo.Migrations.AddShellEnvPolicyFields do
  use Ecto.Migration

  def change do
    alter table(:tool_policies) do
      add :shell_env_allowlist, {:array, :string}, null: false, default: []
    end
  end
end
