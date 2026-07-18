defmodule HydraAgent.SimLab.Calibrations do
  @moduledoc "Stores observed outcomes beside their forecast for later model review."

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.Schemas.{ActionPattern, CalibrationRecord, SimulationRun, Study}

  @material_drift 0.10

  def record(%Study{} = study, %SimulationRun{} = run, attrs) do
    attrs = Map.new(attrs)
    metric = Map.get(attrs, :metric) || Map.get(attrs, "metric")
    actual = Map.get(attrs, :actual_value) || Map.get(attrs, "actual_value")

    with {:ok, actual} <- parse_value(actual),
         forecast when is_number(forecast) <- Map.get(run.aggregate_metrics, metric) do
      %CalibrationRecord{}
      |> CalibrationRecord.changeset(%{
        study_id: study.id,
        run_id: run.id,
        metric: metric,
        forecast_value: forecast,
        actual_value: actual,
        delta: Float.round(actual - forecast, 4),
        note: Map.get(attrs, :note) || Map.get(attrs, "note"),
        observed_at: DateTime.utc_now()
      })
      |> Repo.insert()
    else
      _ -> {:error, :invalid_calibration}
    end
  end

  def list(%SimulationRun{id: run_id}), do: list(run_id)

  def list(run_id) do
    CalibrationRecord
    |> where([record], record.run_id == ^run_id)
    |> order_by([record], desc: record.observed_at, desc: record.id)
    |> Repo.all()
  end

  @doc """
  Summarizes calibration drift as an explicit review prompt. It is advisory:
  no behavior record or original forecast is changed by this function.
  """
  def review([]) do
    %{
      tone: "waiting",
      label: "Awaiting observed outcome",
      headline: "No calibration signal yet.",
      body: "Record a measured outcome to compare this directional forecast with reality."
    }
  end

  def review(records) do
    record = Enum.max_by(records, &abs(&1.delta))
    points = round(abs(record.delta) * 100)

    cond do
      points <= 5 ->
        %{
          tone: "aligned",
          label: "Calibration looks aligned",
          headline:
            "#{String.capitalize(record.metric)} is within #{points} points of the forecast.",
          body:
            "Keep collecting outcomes before changing the behavior model; one observation is not a new rule."
        }

      points <= 15 ->
        %{
          tone: "watch",
          label: "Minor drift to watch",
          headline: "#{String.capitalize(record.metric)} differs by #{points} points.",
          body:
            "Check the scenario timing and linked evidence when the next outcome arrives. Do not silently rewrite the model."
        }

      true ->
        %{
          tone: "review",
          label: "Model review recommended",
          headline: "#{String.capitalize(record.metric)} differs by #{points} points.",
          body:
            "Review the linked action patterns, evidence coverage, and scenario assumptions before relying on another forecast."
        }
    end
  end

  @doc """
  Produces explicit confidence-only revisions for materially drifted action
  patterns. Proposals never alter a pattern until the researcher applies one.
  """
  def proposals(%Study{} = study, %SimulationRun{} = run) do
    records = latest_records(run)
    captured_versions = captured_pattern_versions(run)

    ActionPattern
    |> where([pattern], pattern.study_id == ^study.id and pattern.status == "active")
    |> order_by([pattern], asc: pattern.inserted_at, asc: pattern.id)
    |> Repo.all()
    |> Enum.filter(&captured_pattern?(&1, captured_versions))
    |> Enum.flat_map(fn pattern ->
      case record_for(records, pattern.likely_action) do
        nil -> []
        record -> List.wrap(proposal(pattern, record))
      end
    end)
  end

  def apply_proposal(%Study{} = study, %SimulationRun{} = run, pattern_id) do
    with %ActionPattern{} = pattern <- study_pattern(study, pattern_id),
         true <- captured_pattern?(pattern, captured_pattern_versions(run)),
         %CalibrationRecord{} = record <- record_for(latest_records(run), pattern.likely_action),
         %{} = proposal <- proposal(pattern, record) do
      executable_rule =
        Map.merge(pattern.executable_rule || %{}, %{
          "calibration_record_id" => record.id,
          "calibration_delta" => record.delta,
          "calibration_applied_for_future_runs" => true
        })

      pattern
      |> ActionPattern.changeset(%{
        confidence: proposal.suggested_confidence,
        executable_rule: executable_rule
      })
      |> Ecto.Changeset.optimistic_lock(:version)
      |> Repo.update(stale_error_field: :version)
      |> normalize_calibration_update()
    else
      nil -> {:error, :no_calibration_proposal}
      false -> {:error, :no_calibration_proposal}
    end
  end

  defp latest_records(run) do
    run
    |> list()
    |> Enum.uniq_by(& &1.metric)
  end

  defp record_for(records, action), do: Enum.find(records, &(&1.metric == action))

  defp proposal(pattern, record) do
    current_confidence = pattern.confidence || 0.5

    already_applied? =
      to_string(Map.get(pattern.executable_rule || %{}, "calibration_record_id", "")) ==
        to_string(record.id)

    if abs(record.delta) >= @material_drift and not already_applied? do
      shift = Float.round(min(0.25, abs(record.delta) / 2), 2)
      suggested_confidence = Float.round(max(0.1, current_confidence - shift), 2)

      %{
        pattern_id: pattern.id,
        pattern_name: pattern.name,
        metric: record.metric,
        record_id: record.id,
        delta: record.delta,
        current_confidence: current_confidence,
        suggested_confidence: suggested_confidence,
        reason:
          "Measured #{record.metric} differs by #{round(abs(record.delta) * 100)} points. Lower confidence for future runs until the rule is reviewed."
      }
    end
  end

  defp study_pattern(study, pattern_id) do
    ActionPattern
    |> where(
      [pattern],
      pattern.study_id == ^study.id and pattern.id == ^pattern_id and pattern.status == "active"
    )
    |> Repo.one()
  end

  defp normalize_calibration_update({:error, %Ecto.Changeset{} = changeset} = error) do
    if Keyword.has_key?(changeset.errors, :version),
      do: {:error, :no_calibration_proposal},
      else: error
  end

  defp normalize_calibration_update(result), do: result

  defp captured_pattern_versions(%SimulationRun{input_snapshot: snapshot})
       when is_map(snapshot) do
    patterns =
      case map_value(snapshot, "patterns", []) do
        patterns when is_list(patterns) -> patterns
        _ -> []
      end

    patterns
    |> Enum.reduce(%{}, fn pattern, versions ->
      id = map_value(pattern, "id")
      version = map_value(pattern, "version")

      if not is_nil(id) and is_integer(version),
        do: Map.put(versions, to_string(id), version),
        else: versions
    end)
  end

  defp captured_pattern_versions(%SimulationRun{}), do: %{}

  defp captured_pattern?(pattern, versions) do
    Map.get(versions, to_string(pattern.id)) == pattern.version
  end

  defp map_value(map, key, default \\ nil)

  defp map_value(map, "patterns", default),
    do: Map.get(map, "patterns", Map.get(map, :patterns, default))

  defp map_value(map, "id", default), do: Map.get(map, "id", Map.get(map, :id, default))

  defp map_value(map, "version", default),
    do: Map.get(map, "version", Map.get(map, :version, default))

  defp map_value(_value, _key, default), do: default

  defp parse_value(value) when is_number(value), do: {:ok, value * 1.0}

  defp parse_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_value}
    end
  end

  defp parse_value(_), do: {:error, :invalid_value}
end
