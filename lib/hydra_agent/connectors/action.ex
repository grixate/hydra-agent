defmodule HydraAgent.Connectors.Action do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued awaiting_approval approved completed failed rejected)
  @side_effect_classes ~w(read_only workspace_write external_delivery network)

  schema "connector_actions" do
    field :provider, :string
    field :action, :string
    field :side_effect_class, :string
    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :result, :map, default: %{}
    field :last_error, :map, default: %{}
    field :requested_by, :string, default: "agent"
    field :approved_by, :string
    field :approved_at, :utc_datetime_usec
    field :executed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :connector_account, HydraAgent.Connectors.Account
    belongs_to :agent, HydraAgent.Runtime.AgentProfile
    belongs_to :automation, HydraAgent.Automations.Automation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :workspace_id,
      :connector_account_id,
      :agent_id,
      :automation_id,
      :provider,
      :action,
      :side_effect_class,
      :status,
      :input,
      :result,
      :last_error,
      :requested_by,
      :approved_by,
      :approved_at,
      :executed_at,
      :metadata
    ])
    |> validate_required([
      :workspace_id,
      :connector_account_id,
      :provider,
      :action,
      :side_effect_class,
      :status,
      :requested_by
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:side_effect_class, @side_effect_classes)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:connector_account)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:automation)
  end
end
