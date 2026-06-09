defmodule HydraAgent.Plugins.Capability do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(tool tool_bundle agent_pack skill mcp_server connector room_channel cli_command client_surface web_route migration)
  @statuses ~w(enabled disabled blocked)

  schema "plugin_capabilities" do
    field :kind, :string
    field :name, :string
    field :status, :string, default: "enabled"
    field :side_effect_class, :string
    field :spec, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :plugin_installation, HydraAgent.Plugins.Installation

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(capability, attrs) do
    capability
    |> cast(attrs, [
      :workspace_id,
      :plugin_installation_id,
      :kind,
      :name,
      :status,
      :side_effect_class,
      :spec,
      :metadata
    ])
    |> validate_required([:workspace_id, :plugin_installation_id, :kind, :name, :status, :spec])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_.:-]*$/)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:plugin_installation)
    |> unique_constraint([:workspace_id, :kind, :name])
  end
end
