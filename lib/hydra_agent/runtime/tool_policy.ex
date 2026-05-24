defmodule HydraAgent.Runtime.ToolPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Runtime.Autonomy

  schema "tool_policies" do
    field :scope, :string, default: "agent"
    field :allowed_tools, {:array, :string}, default: []
    field :side_effect_classes, {:array, :string}, default: ["read_only"]
    field :network_allowlist, {:array, :string}, default: []
    field :shell_allowlist, {:array, :string}, default: []
    field :filesystem_allowlist, {:array, :string}, default: []
    field :filesystem_denylist, {:array, :string}, default: []
    field :requires_approval, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :agent, HydraAgent.Runtime.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :scope,
      :allowed_tools,
      :side_effect_classes,
      :network_allowlist,
      :shell_allowlist,
      :filesystem_allowlist,
      :filesystem_denylist,
      :requires_approval,
      :metadata
    ])
    |> validate_required([:workspace_id, :scope])
    |> validate_allowed_values(:side_effect_classes, Autonomy.side_effect_classes())
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:agent)
  end

  defp validate_allowed_values(changeset, field, allowed) do
    validate_change(changeset, field, fn ^field, values ->
      unknown = values -- allowed

      if unknown == [],
        do: [],
        else: [{field, "contains unknown values: #{Enum.join(unknown, ", ")}"}]
    end)
  end
end
