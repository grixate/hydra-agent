defmodule HydraAgent.Gateways.WebhookEndpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)
  @target_types ~w(agent_chat run_create)

  schema "webhook_endpoints" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :target_type, :string
    field :token_env, :string
    field :config, :map, default: %{}
    field :last_received_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :name,
      :slug,
      :status,
      :target_type,
      :token_env,
      :config,
      :last_received_at,
      :last_error,
      :metadata
    ])
    |> validate_required([:workspace_id, :name, :slug, :status, :target_type, :token_env])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> validate_format(:token_env, ~r/^[A-Z][A-Z0-9_]*$/,
      message: "must name an environment variable"
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:target_type, @target_types)
    |> validate_agent_for_target()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
    |> unique_constraint([:workspace_id, :slug])
  end

  defp validate_agent_for_target(changeset) do
    target_type = get_field(changeset, :target_type)
    agent_id = get_field(changeset, :agent_id)

    if target_type in ["agent_chat", "run_create"] and is_nil(agent_id) do
      add_error(changeset, :agent_id, "is required for #{target_type}")
    else
      changeset
    end
  end
end
