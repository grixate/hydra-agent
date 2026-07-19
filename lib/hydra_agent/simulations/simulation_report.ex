defmodule HydraAgent.Simulations.SimulationReport do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running ready failed)
  @locales ~w(en ru)
  @audiences ~w(general executive technical)
  @lengths ~w(concise standard detailed)
  @validation_statuses ~w(pending validated rejected)

  schema "simulation_reports" do
    field :version, :integer
    field :status, :string, default: "queued"
    field :locale, :string
    field :audience, :string
    field :length, :string
    field :provider, :string
    field :model, :string
    field :model_route_version, :string
    field :route_snapshot, :map, default: %{}
    field :price_snapshot, :map, default: %{}
    field :currency, :string, default: "USD"
    field :pricing_known, :boolean, default: false
    field :max_input_tokens, :integer
    field :max_output_tokens, :integer
    field :reserved_cost, :decimal
    field :actual_input_tokens, :integer
    field :actual_output_tokens, :integer
    field :actual_cost, :decimal
    field :blueprint_version_hash, :string
    field :instructions_hash, :string
    field :analysis_hash, :string
    field :title, :string
    field :summary, :string
    field :sections, {:array, :map}, default: []
    field :limitations, {:array, :string}, default: []
    field :recommended_next_steps, {:array, :string}, default: []
    field :validation_status, :string, default: "pending"
    field :validation_errors, {:array, :map}, default: []
    field :content_hash, :string
    field :failure, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workspace, HydraAgent.Runtime.Workspace
    belongs_to :analysis_pack, HydraAgent.Simulations.AnalysisPack
    belongs_to :simulation_run_record, HydraAgent.Simulations.SimulationRunRecord
    belongs_to :source_report, __MODULE__
    belongs_to :created_by_user, HydraAgent.Accounts.User
    belongs_to :provider_config, HydraAgent.Runtime.ProviderConfig

    has_many :regenerations, __MODULE__, foreign_key: :source_report_id

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def locales, do: @locales
  def audiences, do: @audiences
  def lengths, do: @lengths

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :workspace_id,
      :analysis_pack_id,
      :simulation_run_record_id,
      :source_report_id,
      :created_by_user_id,
      :provider_config_id,
      :version,
      :status,
      :locale,
      :audience,
      :length,
      :provider,
      :model,
      :model_route_version,
      :route_snapshot,
      :price_snapshot,
      :currency,
      :pricing_known,
      :max_input_tokens,
      :max_output_tokens,
      :reserved_cost,
      :actual_input_tokens,
      :actual_output_tokens,
      :actual_cost,
      :blueprint_version_hash,
      :instructions_hash,
      :analysis_hash,
      :title,
      :summary,
      :sections,
      :limitations,
      :recommended_next_steps,
      :validation_status,
      :validation_errors,
      :content_hash,
      :failure,
      :started_at,
      :completed_at
    ])
    |> validate_required([
      :workspace_id,
      :analysis_pack_id,
      :simulation_run_record_id,
      :provider_config_id,
      :version,
      :status,
      :locale,
      :audience,
      :length,
      :provider,
      :model,
      :model_route_version,
      :route_snapshot,
      :price_snapshot,
      :currency,
      :pricing_known,
      :max_input_tokens,
      :max_output_tokens,
      :blueprint_version_hash,
      :instructions_hash,
      :analysis_hash,
      :sections,
      :limitations,
      :recommended_next_steps,
      :validation_status,
      :validation_errors,
      :failure
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:locale, @locales)
    |> validate_inclusion(:audience, @audiences)
    |> validate_inclusion(:length, @lengths)
    |> validate_inclusion(:validation_status, @validation_statuses)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:max_input_tokens, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:max_output_tokens, greater_than: 0, less_than_or_equal_to: 30_000)
    |> validate_optional_nonnegative(:reserved_cost)
    |> validate_optional_nonnegative(:actual_input_tokens)
    |> validate_optional_nonnegative(:actual_output_tokens)
    |> validate_optional_nonnegative(:actual_cost)
    |> validate_length(:provider, min: 1, max: 120)
    |> validate_length(:model, min: 1, max: 180)
    |> validate_length(:model_route_version, min: 1, max: 128)
    |> validate_length(:title, max: 180)
    |> validate_length(:summary, max: 1_500)
    |> validate_length(:sections, max: 12)
    |> validate_length(:limitations, max: 12)
    |> validate_length(:recommended_next_steps, max: 12)
    |> validate_length(:validation_errors, max: 32)
    |> validate_hash(:blueprint_version_hash)
    |> validate_hash(:instructions_hash)
    |> validate_hash(:analysis_hash)
    |> validate_optional_hash(:content_hash)
    |> validate_terminal_shape()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:analysis_pack_id)
    |> foreign_key_constraint(:simulation_run_record_id)
    |> foreign_key_constraint(:source_report_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:provider_config_id)
    |> unique_constraint([:analysis_pack_id, :version])
    |> check_constraint(:status, name: :simulation_reports_status_check)
    |> check_constraint(:version, name: :simulation_reports_configuration_check)
    |> check_constraint(:status, name: :simulation_reports_terminal_check)
  end

  defp validate_terminal_shape(changeset) do
    case get_field(changeset, :status) do
      "ready" ->
        changeset
        |> validate_required([
          :title,
          :summary,
          :content_hash,
          :actual_input_tokens,
          :actual_output_tokens,
          :completed_at
        ])
        |> require_validation("validated")

      "failed" ->
        changeset
        |> validate_required([:completed_at])
        |> require_validation("rejected")

      _status ->
        require_validation(changeset, "pending")
    end
  end

  defp require_validation(changeset, expected) do
    if get_field(changeset, :validation_status) == expected,
      do: changeset,
      else: add_error(changeset, :validation_status, "must be #{expected}")
  end

  defp validate_hash(changeset, field),
    do: validate_format(changeset, field, ~r/^[a-f0-9]{64}$/)

  defp validate_optional_hash(changeset, field) do
    if is_nil(get_field(changeset, field)), do: changeset, else: validate_hash(changeset, field)
  end

  defp validate_optional_nonnegative(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: validate_number(changeset, field, greater_than_or_equal_to: 0)
  end
end
