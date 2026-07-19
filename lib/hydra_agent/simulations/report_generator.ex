defmodule HydraAgent.Simulations.ReportGenerator do
  @moduledoc "Queues and executes bounded, immutable Report generation attempts."

  import Ecto.Query
  require Logger

  alias HydraAgent.{Accounts, Providers, Repo}
  alias HydraAgent.Runtime.ProviderConfig

  alias HydraAgent.Simulations.{
    AnalysisPack,
    ContentHash,
    ModelRouter,
    PriceRegistry,
    ReportValidator,
    SimulationReport
  }

  alias HydraAgent.Simulations.Workers.ReportGenerationWorker

  @output_envelopes %{"concise" => 2_500, "standard" => 6_000, "detailed" => 10_000}

  def queue(%AnalysisPack{} = pack, user, attrs \\ %{}) when is_map(attrs) do
    attrs = stringify_map(attrs)
    pack = load_pack(pack.id)

    cond do
      not Accounts.workspace_authorized?(user, pack.workspace_id, "researcher") ->
        {:error, :forbidden}

      attrs["source_report_id"] && not valid_source?(pack, attrs["source_report_id"]) ->
        {:error, :invalid_source_report}

      true ->
        with {:ok, config} <- configuration(pack, attrs),
             {:ok, report} <- persist_queue(pack, user, attrs, config) do
          {:ok, report}
        end
    end
  end

  def generate(report_id, attempt \\ 1) when is_integer(attempt) and attempt > 0 do
    case claim(report_id, attempt) do
      {:ok, :terminal} ->
        :ok

      {:ok, :already_running} ->
        :ok

      {:ok, :interrupted} ->
        :ok

      {:ok, report} ->
        execute(report)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error(
        "report generation stopped safely report_id=#{report_id} error=#{Exception.message(error)}"
      )

      _result = fail_active(report_id, :report_generation_exception)
      {:error, :report_generation_exception}
  catch
    kind, reason ->
      Logger.error(
        "report generation exited safely report_id=#{report_id} reason=#{inspect({kind, reason})}"
      )

      _result = fail_active(report_id, :report_generation_exit)
      {:error, :report_generation_exit}
  end

  def prompt(%SimulationReport{} = report) do
    report = load_report(report.id)
    pack = report.analysis_pack
    blueprint = pack.simulation_run_record.simulation_version.blueprint_version
    instructions = blueprint.instructions["report"] || ""

    %{
      "model" => report.model,
      "temperature" => 0,
      "max_tokens" => report.max_output_tokens,
      "messages" => [
        %{
          "role" => "system",
          "content" => system_instruction(report, instructions)
        },
        %{
          "role" => "user",
          "content" => Jason.encode!(AnalysisPack.payload(pack))
        }
      ],
      "metadata" => %{
        "hydra_analysis_report" => true,
        "analysis_hash" => pack.content_hash,
        "locale" => report.locale,
        "audience" => report.audience,
        "length" => report.length,
        "reference_ids" => pack.reference_index |> Map.keys() |> Enum.sort(),
        "primary_reference" => primary_reference(pack)
      }
    }
  end

  defp persist_queue(pack, user, attrs, config) do
    Repo.transaction(fn ->
      locked_pack =
        AnalysisPack
        |> where([current], current.id == ^pack.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      version = next_version(locked_pack.id)

      report_attrs = %{
        workspace_id: locked_pack.workspace_id,
        analysis_pack_id: locked_pack.id,
        simulation_run_record_id: locked_pack.simulation_run_record_id,
        source_report_id: normalize_optional_id(attrs["source_report_id"]),
        created_by_user_id: user && user.id,
        provider_config_id: config.provider.id,
        version: version,
        status: "queued",
        locale: config.locale,
        audience: config.audience,
        length: config.length,
        provider: config.route["provider"],
        model: config.route["model"],
        model_route_version: config.route["route_version"],
        route_snapshot: config.route,
        price_snapshot: config.price,
        currency: config.currency,
        pricing_known: config.price["pricing"] == "known",
        max_input_tokens: config.max_input_tokens,
        max_output_tokens: config.max_output_tokens,
        reserved_cost: config.reserved_cost,
        blueprint_version_hash: config.blueprint_hash,
        instructions_hash: config.instructions_hash,
        analysis_hash: locked_pack.content_hash,
        sections: [],
        limitations: [],
        recommended_next_steps: [],
        validation_status: "pending",
        validation_errors: [],
        failure: %{}
      }

      report = %SimulationReport{} |> SimulationReport.changeset(report_attrs) |> Repo.insert!()

      case Oban.insert(ReportGenerationWorker.new(%{"simulation_report_id" => report.id})) do
        {:ok, _job} -> report
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
    error in Postgrex.Error -> {:error, safe_database_error(error)}
  end

  defp configuration(pack, attrs) do
    locale = selection(attrs["locale"], pack.setup["locale"], SimulationReport.locales())
    audience = selection(attrs["audience"], "general", SimulationReport.audiences())
    length = selection(attrs["length"], "standard", SimulationReport.lengths())

    with true <- locale in SimulationReport.locales(),
         true <- audience in SimulationReport.audiences(),
         true <- length in SimulationReport.lengths(),
         {:ok, route, provider} <- select_route(pack, attrs["provider_config_id"]),
         true <- locale_supported?(route, locale),
         {:ok, envelope} <- token_envelope(pack, length) do
      blueprint = pack.simulation_run_record.simulation_version.blueprint_version
      instructions = blueprint.instructions["report"] || ""
      snapshot = PriceRegistry.snapshot(pack.workspace_id, %{"report" => route})
      price = get_in(snapshot, ["entries", "report"]) || %{"pricing" => "unknown"}
      reserved_cost = PriceRegistry.estimate_max(price, envelope.input, envelope.output)

      {:ok,
       %{
         locale: locale,
         audience: audience,
         length: length,
         route: route,
         provider: provider,
         price: price,
         currency: price["currency"] || snapshot["currency"] || "USD",
         reserved_cost: reserved_cost,
         max_input_tokens: envelope.input,
         max_output_tokens: envelope.output,
         blueprint_hash: blueprint.content_hash,
         instructions_hash: ContentHash.digest(instructions)
       }}
    else
      false -> {:error, :invalid_report_configuration}
      {:error, _reason} = error -> error
    end
  end

  defp select_route(pack, selected_id) do
    routes = ModelRouter.available_routes(pack.workspace_id)

    route =
      if selected_id in [nil, ""] do
        preferred = get_in(pack.simulation_run_record.model_route_snapshot, ["report", "id"])
        Enum.find(routes, &(&1["id"] == to_string(preferred))) || List.first(routes)
      else
        Enum.find(routes, &(&1["id"] == to_string(selected_id)))
      end

    with %{} <- route,
         true <- get_in(route, ["capabilities", "structured_generation"]) == true,
         %ProviderConfig{} = provider <- Repo.get(ProviderConfig, route["id"]) do
      {:ok, Map.put(route, "status", "resolved"), provider}
    else
      _other -> {:error, :report_route_unavailable}
    end
  end

  defp token_envelope(pack, length) do
    report_cap =
      get_in(pack.simulation_run_record.budget_plan.stage_caps, ["report"]) || %{}

    input_cap = report_cap["input_tokens"] || 30_000
    output_cap = report_cap["output_tokens"] || 8_000
    estimated_input = estimate_tokens(AnalysisPack.payload(pack)) + 1_200

    if estimated_input > input_cap do
      {:error, :analysis_exceeds_report_input_envelope}
    else
      {:ok,
       %{
         input: max(input_cap, 1),
         output: min(@output_envelopes[length], output_cap) |> max(1)
       }}
    end
  end

  defp claim(report_id, attempt) do
    Repo.transaction(fn ->
      report =
        SimulationReport
        |> where([current], current.id == ^report_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case report.status do
        "queued" ->
          report
          |> SimulationReport.changeset(%{status: "running", started_at: DateTime.utc_now()})
          |> Repo.update!()
          |> load_report()

        "running" when attempt > 1 ->
          mark_failed!(report, :interrupted_provider_request, [])
          :interrupted

        "running" ->
          :already_running

        _terminal ->
          :terminal
      end
    end)
  end

  defp execute(report) do
    case Providers.chat(report.provider_config, prompt(report)) do
      {:ok, response} -> handle_response(report, response)
      {:error, reason} -> fail(report, {:provider_error, reason})
    end
  end

  defp handle_response(report, response) do
    content = get_in(response, ["message", "content"])

    with true <- is_binary(content),
         {:ok, payload} <- Jason.decode(content),
         {:ok, normalized} <- ReportValidator.validate(report.analysis_pack, payload),
         {:ok, usage} <- valid_usage(response["usage"], report) do
      complete(report, normalized, usage)
    else
      false -> fail(report, :missing_report_content)
      {:error, %Jason.DecodeError{}} -> fail(report, :invalid_report_json)
      {:error, errors} when is_list(errors) -> fail(report, :report_validation_failed, errors)
      {:error, reason} -> fail(report, reason)
    end
  end

  defp complete(report, payload, usage) do
    actual_cost = PriceRegistry.estimate_max(report.price_snapshot, usage.input, usage.output)

    contract =
      Map.merge(payload, %{
        "analysis_hash" => report.analysis_hash,
        "blueprint_version_hash" => report.blueprint_version_hash,
        "instructions_hash" => report.instructions_hash,
        "locale" => report.locale,
        "audience" => report.audience,
        "length" => report.length,
        "provider" => report.provider,
        "model" => report.model,
        "model_route_version" => report.model_route_version
      })

    attrs = %{
      status: "ready",
      title: payload["title"],
      summary: payload["summary"],
      sections: payload["sections"],
      limitations: payload["limitations"],
      recommended_next_steps: payload["recommended_next_steps"],
      validation_status: "validated",
      validation_errors: [],
      actual_input_tokens: usage.input,
      actual_output_tokens: usage.output,
      actual_cost: actual_cost,
      content_hash: ContentHash.digest(contract),
      failure: %{},
      completed_at: DateTime.utc_now()
    }

    report
    |> SimulationReport.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, ready} -> {:ok, ready}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp fail(report, reason, validation_errors \\ []) do
    result =
      Repo.transaction(fn ->
        locked =
          SimulationReport
          |> where([current], current.id == ^report.id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        if locked.status in ~w(queued running),
          do: mark_failed!(locked, reason, validation_errors),
          else: locked
      end)

    case result do
      {:ok, failed} -> {:error, {:report_failed, failed.id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fail_active(report_id, reason) do
    case Repo.get(SimulationReport, report_id) do
      %SimulationReport{status: status} = report when status in ~w(queued running) ->
        fail(report, reason)

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp mark_failed!(report, reason, validation_errors) do
    report
    |> SimulationReport.changeset(%{
      status: "failed",
      validation_status: "rejected",
      validation_errors: Enum.take(validation_errors, 32),
      failure: safe_failure(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp valid_usage(usage, report) when is_map(usage) do
    input = integer(usage["input_tokens"] || usage[:input_tokens])
    output = integer(usage["output_tokens"] || usage[:output_tokens])

    if is_integer(input) and is_integer(output) and input >= 0 and output >= 0 and
         input <= report.max_input_tokens and output <= report.max_output_tokens,
       do: {:ok, %{input: input, output: output}},
       else: {:error, :invalid_report_usage}
  end

  defp valid_usage(_usage, _report), do: {:error, :invalid_report_usage}

  defp system_instruction(report, blueprint_instructions) do
    """
    #{blueprint_instructions}

    Return one JSON object only with exactly these keys: title, summary, sections, limitations, recommended_next_steps.
    sections must contain exactly nine objects with exactly heading, body, references.
    The ordered sections cover: setup and question; concise result; world evolution; group differences; resource and influence flows; pivotal drivers; uncertainty and assumptions; validation and next simulation; cost and configuration.
    Every section needs one or more references copied exactly from the Analysis Pack reference_index. Every number in a body must match a numeric_values entry from that section's references. Do not add URLs. Quote agents only from a decision or trace reference.
    Write in #{report.locale} for a #{report.audience} audience at #{report.length} length. Use directional, non-causal language and distinguish simulation output from observed evidence.
    """
  end

  defp load_pack(id) do
    AnalysisPack
    |> Repo.get!(id)
    |> Repo.preload(
      [
        simulation_run_record: [
          :budget_plan,
          simulation_version: :blueprint_version
        ]
      ],
      in_parallel: false
    )
  end

  defp load_report(%SimulationReport{} = report), do: load_report(report.id)

  defp load_report(id) do
    SimulationReport
    |> Repo.get!(id)
    |> Repo.preload(
      [
        :provider_config,
        analysis_pack: [
          simulation_run_record: [
            :budget_plan,
            simulation_version: :blueprint_version
          ]
        ]
      ],
      in_parallel: false
    )
  end

  defp primary_reference(pack) do
    metric = pack.metrics |> List.first() |> then(&(&1 && &1["ref"]))
    metric || "setup:run"
  end

  defp valid_source?(pack, source_id) do
    SimulationReport
    |> where([report], report.id == ^source_id and report.analysis_pack_id == ^pack.id)
    |> Repo.exists?()
  end

  defp next_version(pack_id) do
    SimulationReport
    |> where([report], report.analysis_pack_id == ^pack_id)
    |> select([report], coalesce(max(report.version), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp selection(value, fallback, allowed) do
    value = if value in [nil, ""], do: fallback, else: to_string(value)
    if value in allowed, do: value, else: nil
  end

  defp locale_supported?(route, locale) do
    case get_in(route, ["capabilities", "languages"]) do
      languages when is_list(languages) -> locale in languages
      _other -> true
    end
  end

  defp normalize_optional_id(value) when value in [nil, ""], do: nil
  defp normalize_optional_id(value), do: value

  defp estimate_tokens(value),
    do: value |> Jason.encode!() |> byte_size() |> then(&ceil(&1 / 3.5))

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp safe_failure(reason) do
    %{
      "code" =>
        case reason do
          atom when is_atom(atom) -> Atom.to_string(atom)
          {atom, _detail} when is_atom(atom) -> Atom.to_string(atom)
          _other -> "report_generation_failed"
        end
    }
  end

  defp safe_database_error(%Postgrex.Error{postgres: %{message: message}}),
    do: {:report_not_queued, message}

  defp safe_database_error(_error), do: :report_not_queued
end
