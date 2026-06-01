defmodule HydraAgent.Runtime.ToolPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  alias HydraAgent.Runtime.Autonomy
  alias HydraAgent.Tools.Registry

  schema "tool_policies" do
    field :scope, :string, default: "agent"
    field :allowed_tools, {:array, :string}, default: []
    field :side_effect_classes, {:array, :string}, default: ["read_only"]
    field :network_allowlist, {:array, :string}, default: []
    field :shell_allowlist, {:array, :string}, default: []
    field :shell_env_allowlist, {:array, :string}, default: []
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
      :shell_env_allowlist,
      :filesystem_allowlist,
      :filesystem_denylist,
      :requires_approval,
      :metadata
    ])
    |> validate_required([:workspace_id, :scope])
    |> validate_allowed_values(:allowed_tools, Registry.names())
    |> validate_allowed_values(:side_effect_classes, Autonomy.side_effect_classes())
    |> validate_shell_env_allowlist()
    |> validate_known_bundle_expansion()
    |> validate_dangerous_approval()
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

  defp validate_known_bundle_expansion(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      case metadata do
        %{"unknown_tool_bundles" => unknown} when is_list(unknown) ->
          [metadata: "contains unknown tool bundles: #{Enum.join(unknown, ", ")}"]

        _metadata ->
          []
      end
    end)
  end

  defp validate_shell_env_allowlist(changeset) do
    validate_change(changeset, :shell_env_allowlist, fn :shell_env_allowlist, refs ->
      invalid =
        Enum.reject(refs, fn
          "*" -> true
          ref when is_binary(ref) -> Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, ref)
          _ref -> false
        end)

      if invalid == [] do
        []
      else
        [shell_env_allowlist: "contains invalid environment names: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end

  defp validate_dangerous_approval(changeset) do
    side_effect_classes = get_field(changeset, :side_effect_classes) || []
    requires_approval = get_field(changeset, :requires_approval)

    dangerous = side_effect_classes -- ["read_only"]

    if dangerous != [] and requires_approval == false do
      add_error(changeset, :requires_approval, "must be true for dangerous side effects")
    else
      changeset
    end
  end
end
