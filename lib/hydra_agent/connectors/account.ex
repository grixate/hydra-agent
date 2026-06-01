defmodule HydraAgent.Connectors.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(email calendar notion notes youtube x linkedin telegram)
  @statuses ~w(active paused archived)

  schema "connector_accounts" do
    field :provider, :string
    field :slug, :string
    field :display_name, :string
    field :status, :string, default: "active"
    field :credential_env, :string
    field :refresh_env, :string
    field :config, :map, default: %{}
    field :capabilities, {:array, :string}, default: []
    field :last_health, :map, default: %{}
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :actions, HydraAgent.Connectors.Action, foreign_key: :connector_account_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :workspace_id,
      :provider,
      :slug,
      :display_name,
      :status,
      :credential_env,
      :refresh_env,
      :config,
      :capabilities,
      :last_health,
      :last_error,
      :metadata
    ])
    |> validate_required([:workspace_id, :provider, :slug, :display_name, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_env_ref(:credential_env)
    |> validate_env_ref(:refresh_env)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_env_ref(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) or value == "" -> []
        Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, value) -> []
        true -> [{field, "must be an environment variable name"}]
      end
    end)
  end
end
