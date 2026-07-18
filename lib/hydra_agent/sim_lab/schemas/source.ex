defmodule HydraAgent.SimLab.Schemas.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(upload paste web connector manual_note)
  @statuses ~w(pending parsed failed deleted)
  @pii_statuses ~w(unknown none suspected confirmed redacted)

  schema "sim_lab_sources" do
    field :kind, :string
    field :title, :string
    field :uri, :string
    field :content_hash, :string
    field :raw_object_key, :string
    field :parsed_text, :string
    field :metadata, :map, default: %{}
    field :pii_status, :string, default: "unknown"
    field :access_policy, :map, default: %{}
    field :status, :string, default: "pending"

    belongs_to :study, HydraAgent.SimLab.Schemas.Study
    belongs_to :workspace, HydraAgent.Runtime.Workspace
    has_many :evidence_items, HydraAgent.SimLab.Schemas.EvidenceItem

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :study_id,
      :workspace_id,
      :kind,
      :title,
      :uri,
      :content_hash,
      :raw_object_key,
      :parsed_text,
      :metadata,
      :pii_status,
      :access_policy,
      :status
    ])
    |> validate_required([
      :study_id,
      :workspace_id,
      :kind,
      :title,
      :content_hash,
      :pii_status,
      :status
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:pii_status, @pii_statuses)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:study_id)
    |> foreign_key_constraint(:workspace_id)
  end
end
