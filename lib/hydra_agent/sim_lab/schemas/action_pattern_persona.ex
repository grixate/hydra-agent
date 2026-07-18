defmodule HydraAgent.SimLab.Schemas.ActionPatternPersona do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sim_lab_action_pattern_personas" do
    belongs_to :action_pattern, HydraAgent.SimLab.Schemas.ActionPattern
    belongs_to :persona, HydraAgent.SimLab.Schemas.Persona

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:action_pattern_id, :persona_id])
    |> validate_required([:action_pattern_id, :persona_id])
    |> assoc_constraint(:action_pattern)
    |> assoc_constraint(:persona)
    |> unique_constraint([:action_pattern_id, :persona_id])
  end
end
