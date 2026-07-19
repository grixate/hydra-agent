defmodule HydraAgent.Simulations.SimulationPack do
  @moduledoc "Portable `.hydra-simpack` compilation, inspection, and validation."

  alias HydraAgent.Repo

  alias HydraAgent.Simulations.{
    BlueprintPackage,
    BudgetPlan,
    ContentHash,
    IdentityRedactor,
    InputContract,
    ModelRoutePlan,
    PopulationModel,
    PopulationValidator,
    PortableArchive,
    ScriptValidator,
    Simulation,
    SimulationScript
  }

  @format_version 1
  @required_files ~w(
    README.md
    blueprint.hydra-blueprint
    simulation-version.json
    context-pack.json
    population-model.json
    simulation-script.json
    observation-plan.json
    model-route-plan.json
    budget-plan.json
    preview.json
  )

  def format_version, do: @format_version
  def limits, do: PortableArchive.limits()

  def export(%Simulation{} = simulation, opts \\ []) do
    simulation =
      Repo.preload(simulation, [
        :active_version,
        :active_context_pack,
        :active_population_model,
        active_script: :preview,
        selected_blueprint: :active_version
      ])

    route_plan = Keyword.fetch!(opts, :model_route_plan)
    budget_plan = Keyword.fetch!(opts, :budget_plan)
    privacy = normalize_privacy(opts)

    with :ok <- require_complete(simulation, route_plan, budget_plan),
         {:ok, blueprint_export} <-
           BlueprintPackage.export(simulation.selected_blueprint.active_version) do
      components = components(simulation, route_plan, budget_plan, privacy)
      components = maybe_redact(components, privacy)
      components = maybe_omit_provider_details(components, privacy)
      components = relink_and_rehash(components)

      files =
        %{
          "README.md" => readme(simulation, components, privacy),
          "blueprint.hydra-blueprint" => blueprint_export.binary,
          "simulation-version.json" => PortableArchive.json(components.version),
          "context-pack.json" => PortableArchive.json(components.context),
          "population-model.json" => PortableArchive.json(components.population),
          "simulation-script.json" => PortableArchive.json(components.script),
          "observation-plan.json" => PortableArchive.json(components.observation),
          "model-route-plan.json" => PortableArchive.json(components.route),
          "budget-plan.json" => PortableArchive.json(components.budget),
          "preview.json" => PortableArchive.json(components.preview)
        }
        |> maybe_add_raw_sources(simulation.active_version.inputs, privacy)

      manifest = manifest(simulation, components, blueprint_export, privacy)

      PortableArchive.create(
        :simpack,
        files,
        manifest,
        filename(simulation, components.version["content_hash"])
      )
    end
  end

  def import(binary) when is_binary(binary) do
    with {:ok, archive} <- PortableArchive.import(:simpack, binary),
         :ok <- validate_format_version(archive.manifest),
         :ok <- validate_compatibility(archive.manifest),
         :ok <- validate_privacy_manifest(archive.manifest),
         :ok <- require_files(archive.files, archive.manifest),
         {:ok, blueprint} <- BlueprintPackage.import(archive.files["blueprint.hydra-blueprint"]),
         :ok <- validate_blueprint_lineage(archive.manifest, blueprint),
         {:ok, components} <- decode_components(archive.files),
         :ok <- validate_component_hashes(components),
         :ok <- validate_version(components.version),
         :ok <- validate_context(components.context),
         :ok <- PopulationValidator.validate(components.population),
         {:ok, _report} <-
           ScriptValidator.validate(
             components.script["script"],
             components.population,
             model_budget?: components.version["execution_mode"] == "balanced"
           ),
         :ok <- validate_observation(components.observation, components.script),
         :ok <- validate_preview(components.preview),
         {:ok, inputs} <- decode_inputs(archive.files, archive.manifest) do
      {:ok,
       components
       |> Map.put(:archive, archive)
       |> Map.put(:blueprint, blueprint)
       |> Map.put(:blueprint_binary, archive.files["blueprint.hydra-blueprint"])
       |> Map.put(:inputs, inputs)
       |> Map.put(:privacy, archive.manifest["privacy"] || %{})
       |> Map.put(:warnings, compatibility_warnings(archive.manifest))}
    else
      {:error, errors} when is_list(errors) ->
        error(:semantic_validation_failed, "Simulation Pack failed semantic validation", errors)

      {:error, _reason} = error ->
        error

      other ->
        error(:invalid_simulation_pack, "Simulation Pack could not be validated", other)
    end
  end

  def import(_binary), do: error(:invalid_archive, "Simulation Pack must be binary ZIP data")

  defp components(simulation, route_plan, budget_plan, privacy) do
    version = simulation.active_version
    context = simulation.active_context_pack
    population = simulation.active_population_model
    script = simulation.active_script
    preview = script.preview

    %{
      version: %{
        "schema_version" => 1,
        "title" => version.title,
        "question" => version.question,
        "locale" => version.locale,
        "normalized_input" => version.normalized_input,
        "inputs" => %{"notes" => nil, "urls" => [], "files" => []},
        "input_manifest" => input_manifest(version.inputs, privacy),
        "instruction_overrides" => version.instruction_overrides,
        "research_settings" => version.research_settings,
        "population_size" => version.population_size,
        "execution_mode" => version.execution_mode,
        "budget_preset" => version.budget_preset,
        "model_routes" => version.model_routes,
        "blueprint_version_hash" => simulation.selected_blueprint.active_version.content_hash,
        "source_content_hash" => version.content_hash
      },
      context: context_contract(context),
      population: PopulationModel.contract(population),
      script: SimulationScript.contract(script),
      observation: %{
        "schema_version" => 1,
        "hydra_observation_plan" => 1,
        "observations" => script.script["observations"] || %{}
      },
      route: route_contract(route_plan),
      budget: budget_contract(budget_plan),
      preview: preview_contract(preview)
    }
  end

  defp context_contract(context) do
    %{
      "version" => context.version,
      "interpretation" => context.interpretation,
      "scope" => context.scope,
      "research_plan" => context.research_plan,
      "sources" => context.sources,
      "claims" => context.claims,
      "assumptions" => context.assumptions,
      "gaps" => context.gaps,
      "research_metadata" => context.research_metadata,
      "historical_cutoff" =>
        if(context.historical_cutoff, do: Date.to_iso8601(context.historical_cutoff), else: nil),
      "status" => context.status,
      "confidence" => context.confidence,
      "content_hash" => context.content_hash
    }
  end

  defp route_contract(route_plan) do
    %{
      "selection" => route_plan.selection,
      "resolved_routes" => route_plan.resolved_routes,
      "capability_requirements" => route_plan.capability_requirements,
      "content_hash" => route_plan.content_hash
    }
  end

  defp budget_contract(budget_plan) do
    %{
      "preset" => budget_plan.preset,
      "currency" => budget_plan.currency,
      "pricing_status" => budget_plan.pricing_status,
      "hard_cost_cap" => decimal(budget_plan.hard_cost_cap),
      "hard_input_token_cap" => budget_plan.hard_input_token_cap,
      "hard_output_token_cap" => budget_plan.hard_output_token_cap,
      "hard_model_call_cap" => budget_plan.hard_model_call_cap,
      "hard_retrieval_request_cap" => budget_plan.hard_retrieval_request_cap,
      "hard_runtime_seconds" => budget_plan.hard_runtime_seconds,
      "max_concurrency" => budget_plan.max_concurrency,
      "stage_caps" => budget_plan.stage_caps,
      "price_registry_snapshot" => budget_plan.price_registry_snapshot,
      "model_route_snapshot" => budget_plan.model_route_snapshot,
      "estimates" => budget_plan.estimates,
      "fallback_policy" => budget_plan.fallback_policy,
      "content_hash" => budget_plan.content_hash
    }
  end

  defp preview_contract(preview) do
    %{
      "schema_version" => 1,
      "status" => preview.status,
      "rounds_requested" => preview.rounds_requested,
      "rounds_completed" => preview.rounds_completed,
      "agent_count" => preview.agent_count,
      "seed" => preview.seed,
      "summary" => preview.summary,
      "errors" => preview.errors,
      "result_hash" => preview.result_hash
    }
  end

  defp normalize_privacy(opts) do
    redact = Keyword.get(opts, :redact_identities, false) == true

    %{
      "raw_sources" =>
        if(Keyword.get(opts, :include_raw_sources, false) == true and not redact,
          do: "included",
          else: "excluded"
        ),
      "identities" => if(redact, do: "redacted", else: "original"),
      "provider_details" =>
        if(Keyword.get(opts, :include_provider_details, true) == false,
          do: "omitted",
          else: "included"
        ),
      "redaction_version" => if(redact, do: "hydra-redaction/v1", else: nil)
    }
  end

  defp input_manifest(inputs, privacy) do
    files = (inputs || %{})["files"] || []
    urls = (inputs || %{})["urls"] || []

    manifest = %{
      "notes_present" => is_binary((inputs || %{})["notes"]),
      "files" =>
        Enum.map(files, fn file ->
          Map.take(file, ~w(filename extension media_type size_bytes sha256))
        end),
      "urls" => urls,
      "raw_sources_included" => privacy["raw_sources"] == "included"
    }

    if privacy["identities"] == "redacted" do
      IdentityRedactor.redact(manifest, IdentityRedactor.new([manifest]))
    else
      manifest
    end
  end

  defp maybe_redact(components, %{"identities" => "redacted"}) do
    redactor = IdentityRedactor.new(Map.values(components))
    Map.new(components, fn {key, value} -> {key, IdentityRedactor.redact(value, redactor)} end)
  end

  defp maybe_redact(components, _privacy), do: components

  defp maybe_omit_provider_details(components, %{"provider_details" => "omitted"}) do
    routes =
      Map.new(components.route["resolved_routes"] || %{}, fn {role, route} ->
        sanitized =
          route
          |> Map.drop(~w(id name provider model))
          |> Map.put("provider_details", "omitted")

        {role, sanitized}
      end)

    route =
      components.route
      |> Map.put("selection", portable_selections(components.version["execution_mode"]))
      |> Map.put("resolved_routes", routes)

    budget =
      components.budget
      |> Map.put("model_route_snapshot", routes)
      |> Map.update("price_registry_snapshot", %{}, &omit_price_provider_details/1)

    version =
      Map.put(
        components.version,
        "model_routes",
        portable_selections(components.version["execution_mode"])
      )

    %{components | version: version, route: route, budget: budget}
  end

  defp maybe_omit_provider_details(components, _privacy), do: components

  defp omit_price_provider_details(snapshot) when is_map(snapshot) do
    Map.update(snapshot, "entries", %{}, fn entries ->
      Map.new(entries, fn {role, entry} ->
        {role, Map.drop(entry || %{}, ~w(id name provider model provider_config_id))}
      end)
    end)
  end

  defp omit_price_provider_details(_snapshot), do: %{}

  defp portable_selections("quick"),
    do: %{"build" => "automatic", "simulation" => "none", "report" => "automatic"}

  defp portable_selections(_mode),
    do: %{"build" => "automatic", "simulation" => "automatic", "report" => "automatic"}

  defp relink_and_rehash(components) do
    context = rehash(components.context)

    population =
      components.population
      |> put_in(["generation_metadata", "source_context_hash"], context["content_hash"])
      |> rehash()

    script =
      components.script
      |> put_in(["generation_metadata", "source_context_hash"], context["content_hash"])
      |> put_in(["generation_metadata", "source_population_hash"], population["content_hash"])
      |> rehash()

    observation = rehash(components.observation)
    route = rehash(components.route)

    budget =
      components.budget
      |> Map.put("model_route_snapshot", route["resolved_routes"])
      |> rehash()

    preview =
      components.preview
      |> Map.put("result_hash", ContentHash.digest(components.preview["summary"] || %{}))

    version = rehash(components.version)

    %{
      components
      | version: version,
        context: context,
        population: population,
        script: script,
        observation: observation,
        route: route,
        budget: budget,
        preview: preview
    }
  end

  defp maybe_add_raw_sources(files, inputs, %{"raw_sources" => "included"}) do
    Map.put(files, "raw-sources.json", PortableArchive.json(%{"inputs" => inputs || %{}}))
  end

  defp maybe_add_raw_sources(files, _inputs, _privacy), do: files

  defp manifest(simulation, components, blueprint_export, privacy) do
    %{
      "format_version" => @format_version,
      "created_at" => iso8601(simulation.active_version.inserted_at),
      "hydra_version" => hydra_version(),
      "compatibility" => %{
        "minimum_hydra_version" => "0.1.0",
        "simulation_schema" => 1,
        "context_schema" => 1,
        "population_schema" => 1,
        "script_schema" => 1,
        "observation_schema" => 1,
        "population_compiler" => components.population["compiler_version"],
        "script_compiler" => components.script["compiler_version"],
        "execution_modes" => [components.version["execution_mode"]],
        "required_capabilities" => components.route["capability_requirements"] || %{}
      },
      "lineage" => %{
        "blueprint_id" => simulation.selected_blueprint.slug,
        "blueprint_version" => simulation.selected_blueprint.active_version.version,
        "blueprint_content_hash" => blueprint_export.content_hash,
        "simulation_version_hash" => components.version["content_hash"],
        "context_pack_hash" => components.context["content_hash"],
        "population_model_hash" => components.population["content_hash"],
        "simulation_script_hash" => components.script["content_hash"],
        "model_route_plan_hash" => components.route["content_hash"],
        "budget_plan_hash" => components.budget["content_hash"]
      },
      "privacy" => privacy,
      "validation" => %{
        "schema" => "passed",
        "semantic" => "passed",
        "preview" => components.preview["status"]
      }
    }
  end

  defp readme(simulation, components, privacy) do
    raw = privacy["raw_sources"]
    identities = privacy["identities"]

    """
    # Hydra Simulation Pack

    This declarative package contains one validated Simulation Pack. It contains no executable code and no provider credentials.

    ## Import

    1. In Hydra, open Simulations and choose **Import Simulation Pack**.
    2. Select this `.hydra-simpack` file.
    3. Hydra verifies archive safety, every file hash, format and schema compatibility, model capabilities, semantic rules, and a bounded preview before saving a runnable Simulation.

    Unsupported versions fail before any Simulation is created and include an upgrade or re-export instruction.

    ## Reproduce

    - Blueprint content hash: `#{simulation.selected_blueprint.active_version.content_hash}`
    - Simulation Pack content hash: `#{components.version["content_hash"]}`
    - Population seed: `#{components.population["seed"]}`
    - Population compiler: `#{components.population["compiler_version"]}`
    - Script compiler: `#{components.script["compiler_version"]}`
    - Execution mode: `#{components.version["execution_mode"]}`

    Importing preserves the declarative model and hard budget envelope. Deployment-specific provider identifiers and credentials are never exported. Hydra resolves a destination route from the declared capabilities; a missing required capability blocks the import with an actionable message.

    A new Run uses the imported Pack and a recorded seed. Exact replay additionally requires the completed Run's engine version and recorded model decisions, which are carried by a `.hydra-run` package.

    ## Privacy

    - Raw sources: `#{raw}`
    - Structured identities: `#{identities}`

    Raw private attachments are excluded by default. Redacted exports always exclude raw source text because free-form text cannot be guaranteed anonymous through structured-field redaction alone.
    """
  end

  defp require_complete(simulation, route_plan, budget_plan) do
    cond do
      is_nil(simulation.active_version) or is_nil(simulation.active_context_pack) or
        is_nil(simulation.active_population_model) or is_nil(simulation.active_script) or
          is_nil(simulation.active_script.preview) ->
        error(:pack_incomplete, "Simulation must be fully built before export")

      simulation.active_population_model.status != "ready" ->
        error(:population_not_ready, "Population design must be ready before export")

      simulation.active_script.status != "ready" or
          simulation.active_script.preview.status != "passed" ->
        error(:script_not_ready, "Simulation rules must pass preview before export")

      not match?(%ModelRoutePlan{}, route_plan) or not match?(%BudgetPlan{}, budget_plan) ->
        error(:configuration_missing, "Model route and budget plans are required")

      true ->
        :ok
    end
  end

  defp validate_format_version(manifest) do
    case manifest["format_version"] do
      @format_version ->
        :ok

      version when is_integer(version) ->
        error(
          :unsupported_format_version,
          "This Simulation Pack uses format v#{version}; this Hydra supports v#{@format_version}. Upgrade Hydra or re-export the Pack as v#{@format_version}."
        )

      _ ->
        error(:invalid_format_version, "Simulation Pack format_version must be an integer")
    end
  end

  defp validate_compatibility(manifest) do
    compatibility = manifest["compatibility"]

    if not is_map(compatibility) do
      error(:invalid_compatibility, "Simulation Pack compatibility must be an object")
    else
      do_validate_compatibility(compatibility)
    end
  end

  defp do_validate_compatibility(compatibility) do
    minimum = compatibility["minimum_hydra_version"]

    cond do
      not is_binary(minimum) or Version.parse(minimum) == :error ->
        error(:invalid_compatibility, "Simulation Pack minimum Hydra version is invalid")

      Version.compare(hydra_version(), minimum) == :lt ->
        error(
          :hydra_upgrade_required,
          "This Pack requires Hydra #{minimum} or newer; this deployment is #{hydra_version()}. Upgrade Hydra before importing."
        )

      compatibility["simulation_schema"] != 1 or compatibility["population_schema"] != 1 or
        compatibility["script_schema"] != 1 or
        compatibility["context_schema"] != 1 or compatibility["observation_schema"] != 1 ->
        error(
          :unsupported_schema_version,
          "This Pack uses an unsupported schema. Upgrade Hydra or re-export it with schema v1."
        )

      compatibility["population_compiler"] != PopulationModel.compiler_version() ->
        error(
          :unsupported_population_compiler,
          "This Pack requires population compiler #{compatibility["population_compiler"]}; this Hydra supports #{PopulationModel.compiler_version()}."
        )

      compatibility["script_compiler"] != SimulationScript.compiler_version() ->
        error(
          :unsupported_script_compiler,
          "This Pack requires script compiler #{compatibility["script_compiler"]}; this Hydra supports #{SimulationScript.compiler_version()}."
        )

      true ->
        :ok
    end
  end

  defp validate_privacy_manifest(manifest) do
    privacy = manifest["privacy"]

    cond do
      not is_map(privacy) ->
        error(:invalid_privacy_manifest, "Simulation Pack privacy must be an object")

      privacy["raw_sources"] not in ~w(included excluded) ->
        error(:invalid_privacy_manifest, "Simulation Pack raw_sources policy is invalid")

      privacy["identities"] not in ~w(original redacted) ->
        error(:invalid_privacy_manifest, "Simulation Pack identity policy is invalid")

      privacy["provider_details"] not in ~w(included omitted) ->
        error(:invalid_privacy_manifest, "Simulation Pack provider policy is invalid")

      privacy["identities"] == "redacted" and privacy["raw_sources"] != "excluded" ->
        error(:invalid_privacy_manifest, "Redacted Simulation Packs cannot include raw sources")

      privacy["identities"] == "redacted" and
          privacy["redaction_version"] != "hydra-redaction/v1" ->
        error(:invalid_privacy_manifest, "Simulation Pack redaction version is unsupported")

      privacy["identities"] == "original" and not is_nil(privacy["redaction_version"]) ->
        error(:invalid_privacy_manifest, "Unredacted Simulation Packs cannot claim redaction")

      true ->
        :ok
    end
  end

  defp require_files(files, manifest) do
    missing = @required_files -- Map.keys(files)
    privacy = manifest["privacy"] || %{}
    optional = if privacy["raw_sources"] == "included", do: ["raw-sources.json"], else: []
    unexpected = Map.keys(files) -- (@required_files ++ optional)

    cond do
      missing != [] ->
        error(:missing_files, "Simulation Pack is incomplete", missing)

      unexpected != [] ->
        error(:unexpected_files, "Simulation Pack contains unknown files", unexpected)

      privacy["raw_sources"] == "included" and not Map.has_key?(files, "raw-sources.json") ->
        error(:missing_files, "Simulation Pack declares raw sources but does not contain them")

      true ->
        :ok
    end
  end

  defp validate_blueprint_lineage(manifest, blueprint) do
    expected = get_in(manifest, ["lineage", "blueprint_content_hash"])

    if expected == blueprint.content_hash,
      do: :ok,
      else: error(:blueprint_hash_mismatch, "Embedded Blueprint does not match Pack lineage")
  end

  defp decode_components(files) do
    with {:ok, version} <- decode_json(files, "simulation-version.json"),
         {:ok, context} <- decode_json(files, "context-pack.json"),
         {:ok, population} <- decode_json(files, "population-model.json"),
         {:ok, script} <- decode_json(files, "simulation-script.json"),
         {:ok, observation} <- decode_json(files, "observation-plan.json"),
         {:ok, route} <- decode_json(files, "model-route-plan.json"),
         {:ok, budget} <- decode_json(files, "budget-plan.json"),
         {:ok, preview} <- decode_json(files, "preview.json") do
      {:ok,
       %{
         version: version,
         context: context,
         population: population,
         script: script,
         observation: observation,
         route: route,
         budget: budget,
         preview: preview
       }}
    end
  end

  defp decode_json(files, path) do
    case Jason.decode(files[path] || "") do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> error(:invalid_json, "#{path} must contain a JSON object", path)
    end
  end

  defp validate_component_hashes(components) do
    ~w(version context population script observation route budget)a
    |> Enum.reduce_while(:ok, fn key, :ok ->
      component = Map.fetch!(components, key)

      if component["content_hash"] == ContentHash.digest(Map.delete(component, "content_hash")),
        do: {:cont, :ok},
        else: {:halt, error(:component_hash_mismatch, "A component hash does not match", key)}
    end)
  end

  defp validate_version(version) do
    title = version["title"]
    question = version["question"]
    population_size = version["population_size"]

    cond do
      version["schema_version"] != 1 ->
        error(:unsupported_simulation_schema, "Simulation Version schema must be v1")

      not is_binary(title) or String.length(String.trim(title)) not in 3..180 ->
        error(:invalid_simulation_title, "Simulation title must contain 3 to 180 characters")

      not is_binary(question) or String.length(String.trim(question)) not in 10..5_000 ->
        error(
          :invalid_simulation_question,
          "Simulation question must contain 10 to 5,000 characters"
        )

      version["locale"] not in ~w(en ru) ->
        error(:invalid_locale, "Simulation locale must be en or ru")

      not is_integer(population_size) or population_size < 10 or population_size > 100_000 ->
        error(:invalid_population_size, "Population size must be between 10 and 100,000")

      version["execution_mode"] not in ~w(quick balanced) ->
        error(
          :unsupported_execution_mode,
          "Simulation Pack execution mode must be Quick or Balanced"
        )

      version["budget_preset"] not in ~w(quick standard deep) ->
        error(:invalid_budget_preset, "Simulation Pack budget preset is unsupported")

      true ->
        :ok
    end
  end

  defp validate_context(context) do
    required =
      ~w(interpretation scope research_plan sources claims assumptions gaps research_metadata status confidence)

    cond do
      Enum.any?(required, &(not Map.has_key?(context, &1))) ->
        error(:invalid_context_pack, "Context Pack is missing required fields")

      context["status"] not in ~w(ready partial) ->
        error(:invalid_context_pack, "Context Pack status must be ready or partial")

      not valid_historical_cutoff?(context["historical_cutoff"]) ->
        error(:invalid_context_pack, "Context Pack historical cutoff must be an ISO date")

      not is_number(context["confidence"]) or context["confidence"] < 0 or
          context["confidence"] > 1 ->
        error(:invalid_context_pack, "Context Pack confidence must be between 0 and 1")

      true ->
        :ok
    end
  end

  defp valid_historical_cutoff?(nil), do: true

  defp valid_historical_cutoff?(value) when is_binary(value),
    do: match?({:ok, _date}, Date.from_iso8601(value))

  defp valid_historical_cutoff?(_value), do: false

  defp validate_observation(observation, script) do
    cond do
      observation["schema_version"] != 1 or observation["hydra_observation_plan"] != 1 ->
        error(:unsupported_observation_schema, "Observation Plan schema must be v1")

      observation["observations"] != get_in(script, ["script", "observations"]) ->
        error(:observation_mismatch, "Observation Plan does not match Simulation Script")

      true ->
        :ok
    end
  end

  defp validate_preview(preview) do
    cond do
      preview["schema_version"] != 1 or preview["status"] != "passed" ->
        error(:preview_not_passed, "Simulation Pack must contain a passed preview")

      not is_map(preview["summary"]) or
          preview["result_hash"] != ContentHash.digest(preview["summary"]) ->
        error(:preview_hash_mismatch, "Simulation Pack preview result hash does not match")

      true ->
        :ok
    end
  end

  defp decode_inputs(files, manifest) do
    privacy = manifest["privacy"] || %{}

    if privacy["raw_sources"] == "included" do
      with {:ok, raw} <- decode_json(files, "raw-sources.json"),
           {:ok, inputs} <- InputContract.validate(raw["inputs"]) do
        {:ok, inputs}
      end
    else
      {:ok, %{"notes" => nil, "urls" => [], "files" => []}}
    end
  end

  defp compatibility_warnings(manifest) do
    privacy = manifest["privacy"] || %{}

    []
    |> maybe_warning(privacy["raw_sources"] != "included", "raw_sources_excluded")
    |> maybe_warning(privacy["identities"] == "redacted", "identities_redacted")
  end

  defp maybe_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_warning(warnings, false, _warning), do: warnings

  defp rehash(component),
    do:
      Map.put(
        component,
        "content_hash",
        ContentHash.digest(Map.delete(component, "content_hash"))
      )

  defp filename(simulation, hash) do
    slug =
      simulation.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 48)
      |> case do
        "" -> "simulation"
        value -> value
      end

    "#{slug}-#{String.slice(hash, 0, 10)}.hydra-simpack"
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal(value), do: value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp hydra_version do
    case Application.spec(:hydra_agent, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end

  defp error(code, message, detail \\ nil),
    do: {:error, %{code: code, message: message, detail: detail}}
end
