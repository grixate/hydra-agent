defmodule HydraAgent.Simulations do
  @moduledoc "Durable Blueprint-first Simulation and Simulation Version operations."

  import Ecto.Query
  require Logger

  alias Ecto.Multi

  alias HydraAgent.{Accounts, ProductFeatures, Repo}
  alias HydraAgent.Runtime.Workspace
  alias HydraAgent.SimLab.Schemas.Study

  alias HydraAgent.Simulations.{
    Blueprint,
    Blueprints,
    BuildStage,
    ContentHash,
    ContextBuilder,
    ContextPack,
    ContextResearchRun,
    InputContract,
    JsonSchema,
    Simulation,
    SimulationVersion
  }

  @stage_definitions [
    {"understanding_question", 1},
    {"finding_context", 2},
    {"designing_population", 3},
    {"writing_rules", 4},
    {"checking_model", 5},
    {"preparing_run", 6}
  ]

  def stage_definitions, do: @stage_definitions

  def list_simulations(workspace_id) do
    Simulation
    |> where([simulation], simulation.workspace_id == ^workspace_id)
    |> where([simulation], simulation.status != "archived")
    |> order_by([simulation], desc: simulation.updated_at)
    |> preload([:active_version, :active_context_pack, selected_blueprint: :active_version])
    |> Repo.all()
  end

  def list_legacy_studies(workspace_id) do
    Study
    |> join(:left, [study], simulation in Simulation, on: simulation.legacy_study_id == study.id)
    |> where([study, simulation], study.workspace_id == ^workspace_id and is_nil(simulation.id))
    |> order_by([study], desc: study.updated_at)
    |> Repo.all()
  end

  def get_simulation_for_workspace(workspace_id, id) do
    Simulation
    |> where(
      [simulation],
      simulation.workspace_id == ^workspace_id and simulation.id == ^normalize_id(id)
    )
    |> preload([
      :workspace,
      :active_version,
      :active_context_pack,
      selected_blueprint: :active_version
    ])
    |> Repo.one()
  end

  def get_simulation_for_workspace!(workspace_id, id) do
    get_simulation_for_workspace(workspace_id, id) || raise Ecto.NoResultsError
  end

  def list_build_stages(%Simulation{} = simulation) do
    BuildStage
    |> where(
      [stage],
      stage.simulation_id == ^simulation.id and
        stage.simulation_version_id == ^simulation.active_version_id
    )
    |> order_by([stage], asc: stage.ordinal)
    |> Repo.all()
  end

  def latest_context_research_run(%Simulation{} = simulation) do
    ContextResearchRun
    |> where(
      [run],
      run.simulation_id == ^simulation.id and
        run.simulation_version_id == ^simulation.active_version_id
    )
    |> order_by([run], desc: run.inserted_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  def create_simulation(%Workspace{} = workspace, user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with true <- Accounts.workspace_authorized?(user, workspace.id, "researcher"),
         %Blueprint{} = blueprint <-
           Blueprints.get_blueprint_for_workspace(workspace.id, attrs["blueprint_id"]),
         {:ok, prepared} <- prepare_create(attrs, blueprint) do
      persist_simulation(workspace, user, blueprint, prepared)
    else
      false -> {:error, :forbidden}
      nil -> {:error, :invalid_blueprint}
      {:error, _reason} = error -> error
    end
  end

  def duplicate_simulation(%Simulation{} = simulation, user) do
    simulation =
      Repo.preload(simulation, [
        :workspace,
        :active_version,
        :active_context_pack,
        :selected_blueprint
      ])

    attrs = %{
      "title" => copy_title(simulation.title, simulation.locale),
      "question" => simulation.active_version.question,
      "locale" => simulation.active_version.locale,
      "blueprint_id" => simulation.selected_blueprint_id,
      "population_size" => simulation.active_version.population_size,
      "execution_mode" => simulation.active_version.execution_mode,
      "budget_preset" => simulation.active_version.budget_preset,
      "geography" => simulation.active_version.normalized_input["geography"],
      "horizon" => simulation.active_version.normalized_input["horizon"],
      "historical_cutoff" => simulation.active_version.normalized_input["historical_cutoff"],
      "inputs" => simulation.active_version.inputs,
      "source_simulation_id" => simulation.id
    }

    create_simulation(simulation.workspace, user, attrs)
  end

  def archive_simulation(%Simulation{} = simulation, user) do
    if Accounts.workspace_authorized?(user, simulation.workspace_id, "researcher") do
      simulation
      |> Simulation.archive_changeset(DateTime.utc_now())
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  def current_stage(%Simulation{status: status}) when status in ~w(running analyzing), do: :run
  def current_stage(%Simulation{status: "ready"}), do: :results
  def current_stage(%Simulation{}), do: :build

  def ready_summary(%Simulation{} = simulation) do
    version = simulation.active_version

    %{
      population_size: version.population_size,
      agent_types: nil,
      rounds: nil,
      actions: nil,
      resources: nil,
      scheduled_events: nil,
      execution_mode: version.execution_mode,
      maximum_provider_cost: nil,
      maximum_model_decisions: if(version.execution_mode == "quick", do: 0, else: nil)
    }
  end

  def build_context_pack(%Simulation{} = simulation, user, opts \\ []) do
    simulation =
      Repo.preload(simulation, [
        :active_version,
        :active_context_pack,
        selected_blueprint: :active_version
      ])

    if Accounts.workspace_authorized?(user, simulation.workspace_id, "researcher") do
      opts =
        Keyword.put_new(
          opts,
          :excluded_source_ids,
          active_excluded_source_ids(simulation.active_context_pack)
        )
        |> Keyword.put_new(:base_context_pack, simulation.active_context_pack)

      with {:ok, contract} <- ContextBuilder.build(simulation.active_version, opts),
           :ok <-
             validate_context_contract(simulation.selected_blueprint.active_version, contract) do
        persist_context_contract(simulation, user, contract)
      end
    else
      {:error, :forbidden}
    end
  end

  def exclude_context_source(%Simulation{} = simulation, source_id, user)
      when is_binary(source_id) do
    simulation =
      Repo.preload(simulation, [
        :active_version,
        :active_context_pack,
        selected_blueprint: :active_version
      ])

    if Accounts.workspace_authorized?(user, simulation.workspace_id, "researcher") do
      with %ContextPack{} = pack <- simulation.active_context_pack,
           true <- Enum.any?(pack.sources, &(&1["id"] == source_id)),
           {:ok, contract} <- ContextBuilder.rebuild_without(pack, source_id),
           :ok <-
             validate_context_contract(simulation.selected_blueprint.active_version, contract) do
        persist_context_contract(simulation, user, contract)
      else
        nil -> {:error, :context_not_found}
        false -> {:error, :context_source_not_found}
        {:error, _reason} = error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  def queue_context_research(%Simulation{} = simulation, user, provider \\ "web_search") do
    simulation = Repo.preload(simulation, [:active_version, :active_context_pack])

    cond do
      not Accounts.workspace_authorized?(user, simulation.workspace_id, "researcher") ->
        {:error, :forbidden}

      provider == "web_search" and
          not HydraAgent.SimLab.Research.Providers.web_search_configured?() ->
        {:error, :research_not_configured}

      provider == "direct_sources" and
          get_in(simulation.active_version.inputs || %{}, ["urls"]) in [nil, []] ->
        {:error, :no_direct_sources}

      provider not in ~w(web_search direct_sources mock) ->
        {:error, :invalid_research_provider}

      true ->
        enqueue_context_research(simulation, provider)
    end
  end

  def complete_context_research(%ContextResearchRun{} = run, research_output) do
    simulation = get_simulation_for_workspace!(run.workspace_id, run.simulation_id)

    with true <- simulation.active_version_id == run.simulation_version_id,
         {:ok, contract} <-
           ContextBuilder.build(simulation.active_version,
             research_output: research_output,
             base_context_pack: simulation.active_context_pack,
             excluded_source_ids: active_excluded_source_ids(simulation.active_context_pack)
           ),
         :ok <- validate_context_contract(simulation.selected_blueprint.active_version, contract),
         {:ok, persisted} <- persist_context_contract(simulation, nil, contract) do
      failures = Map.get(research_output, :failures, [])
      planned = research_output |> Map.get(:plan, []) |> length()
      failed = length(failures)

      run
      |> ContextResearchRun.changeset(%{
        status: "completed",
        context_pack_id: persisted.context_pack.id,
        planned_lanes: planned,
        completed_lanes: max(planned - failed, 0),
        failed_lanes: failed,
        completed_at: DateTime.utc_now(),
        failure_reason: nil
      })
      |> Repo.update()
      |> case do
        {:ok, completed} -> {:ok, %{run: completed, context_pack: persisted.context_pack}}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :stale_simulation_version}
      {:error, _reason} = error -> error
    end
  end

  def fail_context_research(%ContextResearchRun{} = run, reason) do
    run
    |> ContextResearchRun.changeset(%{
      status: "failed",
      failure_reason: reason |> to_string() |> String.slice(0, 1_000),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp prepare_create(attrs, blueprint) do
    question = attrs |> Map.get("question", "") |> to_string() |> String.trim()
    locale = attrs["locale"] || "en"
    mode = attrs["execution_mode"] || "quick"
    budget_preset = attrs["budget_preset"] || "quick"
    population_size = parse_integer(attrs["population_size"] || default_population(blueprint))

    cond do
      not mode_enabled?(mode) ->
        {:error, :mode_disabled}

      locale not in ~w(en ru) ->
        {:error, :invalid_locale}

      budget_preset not in ~w(quick standard deep) ->
        {:error, :invalid_budget}

      not is_integer(population_size) ->
        {:error, :invalid_population_size}

      true ->
        with {:ok, historical_cutoff} <- normalize_historical_cutoff(attrs["historical_cutoff"]),
             {:ok, inputs} <- InputContract.validate(normalize_inputs(attrs["inputs"] || %{})) do
          title = attrs |> Map.get("title") |> present() || derive_title(question)

          normalized_input = %{
            "question" => question,
            "geography" => present(attrs["geography"]),
            "horizon" => present(attrs["horizon"]),
            "historical_cutoff" => historical_cutoff,
            "strict_historical_cutoff" =>
              blueprint.slug == "decision-replay" and not is_nil(historical_cutoff),
            "source_counts" => %{
              "files" => length(inputs["files"] || []),
              "urls" => length(inputs["urls"] || []),
              "notes" => if(present(inputs["notes"]), do: 1, else: 0)
            }
          }

          version_contract = %{
            "blueprint_version_hash" => blueprint.active_version.content_hash,
            "title" => title,
            "question" => question,
            "locale" => locale,
            "normalized_input" => normalized_input,
            "inputs" => inputs,
            "instruction_overrides" => %{},
            "research_settings" => %{
              "preset" => "quick",
              "web_research" => true,
              "allow_user_content_to_models" => false
            },
            "population_size" => population_size,
            "execution_mode" => mode,
            "budget_preset" => budget_preset,
            "model_routes" => %{
              "build" => "automatic",
              "simulation" => "automatic",
              "report" => "automatic"
            }
          }

          {:ok,
           version_contract
           |> Map.put("content_hash", ContentHash.digest(version_contract))
           |> Map.put(
             "source_simulation_id",
             normalize_optional_id(attrs["source_simulation_id"])
           )}
        end
    end
  end

  defp persist_simulation(workspace, user, blueprint, prepared) do
    author_id = user && user.id

    multi =
      Multi.new()
      |> Multi.insert(
        :simulation,
        Simulation.creation_changeset(%Simulation{}, %{
          workspace_id: workspace.id,
          selected_blueprint_id: blueprint.id,
          owner_user_id: author_id,
          source_simulation_id: prepared["source_simulation_id"],
          title: prepared["title"],
          question: prepared["question"],
          locale: prepared["locale"],
          status: "draft"
        })
      )
      |> Multi.run(:version, fn repo, %{simulation: simulation} ->
        %SimulationVersion{}
        |> SimulationVersion.changeset(%{
          workspace_id: workspace.id,
          simulation_id: simulation.id,
          blueprint_version_id: blueprint.active_version.id,
          created_by_user_id: author_id,
          version: 1,
          title: prepared["title"],
          question: prepared["question"],
          locale: prepared["locale"],
          normalized_input: prepared["normalized_input"],
          inputs: prepared["inputs"],
          instruction_overrides: prepared["instruction_overrides"],
          research_settings: prepared["research_settings"],
          population_size: prepared["population_size"],
          execution_mode: prepared["execution_mode"],
          budget_preset: prepared["budget_preset"],
          model_routes: prepared["model_routes"],
          content_hash: prepared["content_hash"]
        })
        |> repo.insert()
      end)
      |> Multi.run(:context_contract, fn _repo, %{version: version} ->
        with {:ok, contract} <- ContextBuilder.build(version),
             :ok <- validate_context_contract(blueprint.active_version, contract) do
          {:ok, contract}
        end
      end)
      |> Multi.run(:context_pack, fn repo,
                                     %{
                                       simulation: simulation,
                                       version: version,
                                       context_contract: contract
                                     } ->
        insert_context_pack(repo, workspace.id, simulation.id, version.id, author_id, 1, contract)
      end)
      |> Multi.run(:stages, fn repo,
                               %{
                                 simulation: simulation,
                                 version: version,
                                 context_contract: contract
                               } ->
        insert_initial_stages(repo, workspace.id, simulation.id, version.id, contract)
      end)
      |> Multi.run(:activated, fn repo,
                                  %{
                                    simulation: simulation,
                                    version: version,
                                    context_pack: context_pack
                                  } ->
        simulation |> Simulation.activate_build_changeset(version, context_pack) |> repo.update()
      end)

    case Repo.transaction(multi) do
      {:ok, %{activated: simulation}} ->
        simulation =
          Repo.preload(simulation, [
            :workspace,
            :active_version,
            :active_context_pack,
            selected_blueprint: :active_version
          ])

        maybe_queue_initial_context_research(simulation)
        {:ok, simulation}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp insert_initial_stages(repo, workspace_id, simulation_id, version_id, context_contract) do
    Enum.reduce_while(@stage_definitions, {:ok, []}, fn {stage, ordinal}, {:ok, stages} ->
      stage_attrs = initial_stage_attrs(stage, context_contract)

      changeset =
        BuildStage.changeset(%BuildStage{}, %{
          workspace_id: workspace_id,
          simulation_id: simulation_id,
          simulation_version_id: version_id,
          stage: stage,
          ordinal: ordinal,
          status: stage_attrs.status,
          summary: stage_attrs.summary,
          warnings: stage_attrs.warnings,
          started_at: stage_attrs.started_at,
          completed_at: stage_attrs.completed_at
        })

      case repo.insert(changeset) do
        {:ok, inserted} -> {:cont, {:ok, [inserted | stages]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_context_contract(simulation, user, contract) do
    author_id = user && user.id

    Repo.transaction(fn ->
      locked =
        Simulation
        |> where([current], current.id == ^simulation.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()
        |> Repo.preload([
          :active_version,
          :active_context_pack,
          selected_blueprint: :active_version
        ])

      if locked.active_context_pack &&
           locked.active_context_pack.content_hash == contract["content_hash"] do
        %{simulation: locked, context_pack: locked.active_context_pack, created: false}
      else
        next_version =
          ContextPack
          |> where([pack], pack.simulation_version_id == ^locked.active_version_id)
          |> select([pack], max(pack.version))
          |> Repo.one()
          |> case do
            nil -> 1
            version -> version + 1
          end

        context_pack =
          insert_context_pack(
            Repo,
            locked.workspace_id,
            locked.id,
            locked.active_version_id,
            author_id,
            next_version,
            contract
          )
          |> case do
            {:ok, pack} -> pack
            {:error, changeset} -> Repo.rollback(changeset)
          end

        update_context_stages!(locked, context_pack)

        activated =
          locked
          |> Simulation.activate_context_changeset(context_pack)
          |> Repo.update!()

        %{
          simulation:
            Repo.preload(
              activated,
              [
                :workspace,
                :active_version,
                :active_context_pack,
                selected_blueprint: :active_version
              ],
              force: true
            ),
          context_pack: context_pack,
          created: true
        }
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_context_research(simulation, provider) do
    existing =
      ContextResearchRun
      |> where(
        [run],
        run.simulation_version_id == ^simulation.active_version_id and
          run.provider == ^provider and run.status in ["queued", "running"]
      )
      |> order_by([run], desc: run.inserted_at)
      |> limit(1)
      |> Repo.one()

    if existing do
      {:ok, %{run: existing, queued: false}}
    else
      planned_lanes =
        if provider == "direct_sources" do
          0
        else
          case simulation.active_context_pack do
            %ContextPack{research_plan: plan} when is_list(plan) and plan != [] -> length(plan)
            _context_pack -> 4
          end
        end

      run_changeset =
        ContextResearchRun.changeset(%ContextResearchRun{}, %{
          workspace_id: simulation.workspace_id,
          simulation_id: simulation.id,
          simulation_version_id: simulation.active_version_id,
          provider: provider,
          status: "queued",
          input_snapshot: %{
            "simulation_version_hash" => simulation.active_version.content_hash,
            "base_context_hash" =>
              simulation.active_context_pack && simulation.active_context_pack.content_hash,
            "research_preset" =>
              get_in(simulation.active_version.research_settings || %{}, ["preset"]) || "quick"
          },
          planned_lanes: planned_lanes,
          completed_lanes: 0,
          failed_lanes: 0
        })

      Multi.new()
      |> Multi.insert(:run, run_changeset)
      |> Multi.insert(:job, fn %{run: run} ->
        HydraAgent.Simulations.Workers.ContextResearchWorker.new(%{
          "context_research_run_id" => run.id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{run: run}} -> {:ok, %{run: run, queued: true}}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp insert_context_pack(
         repo,
         workspace_id,
         simulation_id,
         simulation_version_id,
         author_id,
         version,
         contract
       ) do
    %ContextPack{}
    |> ContextPack.changeset(%{
      workspace_id: workspace_id,
      simulation_id: simulation_id,
      simulation_version_id: simulation_version_id,
      created_by_user_id: author_id,
      version: version,
      interpretation: contract["interpretation"],
      scope: contract["scope"],
      research_plan: contract["research_plan"],
      sources: contract["sources"],
      claims: contract["claims"],
      assumptions: contract["assumptions"],
      gaps: contract["gaps"],
      research_metadata: contract["research_metadata"],
      historical_cutoff: contract["historical_cutoff"],
      status: contract["status"],
      confidence: contract["confidence"],
      content_hash: contract["content_hash"]
    })
    |> repo.insert()
  end

  defp initial_stage_attrs("understanding_question", _contract) do
    now = DateTime.utc_now()
    %{status: "complete", summary: nil, warnings: [], started_at: now, completed_at: now}
  end

  defp initial_stage_attrs("finding_context", contract) do
    now = DateTime.utc_now()
    status = if contract["status"] == "ready", do: "complete", else: "partial"
    warnings = contract["gaps"] |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
    %{status: status, summary: nil, warnings: warnings, started_at: now, completed_at: now}
  end

  defp initial_stage_attrs(_stage, _contract) do
    %{status: "pending", summary: nil, warnings: [], started_at: nil, completed_at: nil}
  end

  defp update_context_stages!(simulation, context_pack) do
    now = DateTime.utc_now()

    BuildStage
    |> where(
      [stage],
      stage.simulation_id == ^simulation.id and
        stage.simulation_version_id == ^simulation.active_version_id and
        stage.stage == "finding_context"
    )
    |> Repo.one!()
    |> BuildStage.changeset(%{
      status: if(context_pack.status == "ready", do: "complete", else: "partial"),
      summary: nil,
      warnings: context_pack.gaps |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort(),
      started_at: now,
      completed_at: now
    })
    |> Repo.update!()

    BuildStage
    |> where(
      [stage],
      stage.simulation_id == ^simulation.id and
        stage.simulation_version_id == ^simulation.active_version_id and
        stage.ordinal > 2
    )
    |> Repo.update_all(
      set: [status: "pending", summary: nil, warnings: [], started_at: nil, completed_at: nil]
    )
  end

  defp validate_context_contract(blueprint_version, contract) do
    schema_path = get_in(blueprint_version.manifest, ["modules", "research", "output_schema"])
    schema = schema_path && blueprint_version.schemas[schema_path]

    cond do
      is_nil(schema) ->
        {:error, :context_schema_missing}

      true ->
        case JsonSchema.validate(schema, ContextPack.schema_payload(contract)) do
          :ok -> :ok
          {:error, errors} -> {:error, {:invalid_context_pack, errors}}
        end
    end
  end

  defp active_excluded_source_ids(%ContextPack{} = pack) do
    pack.research_metadata
    |> Kernel.||(%{})
    |> Map.get("excluded_source_ids", [])
    |> List.wrap()
  end

  defp active_excluded_source_ids(_pack), do: []

  defp maybe_queue_initial_context_research(%Simulation{} = simulation) do
    provider =
      cond do
        HydraAgent.SimLab.Research.Providers.web_search_configured?() ->
          "web_search"

        get_in(simulation.active_version.inputs || %{}, ["urls"]) not in [nil, []] ->
          "direct_sources"

        true ->
          nil
      end

    if provider do
      case enqueue_context_research(simulation, provider) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "context research could not be queued simulation_id=#{simulation.id} reason=#{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp default_population(blueprint) do
    blueprint.active_version.manifest["variables"]
    |> List.wrap()
    |> Enum.find_value(5_000, fn
      %{"key" => "population_size", "default" => value} -> value
      _ -> nil
    end)
  end

  defp mode_enabled?("quick"), do: true
  defp mode_enabled?("balanced"), do: ProductFeatures.enabled?(:balanced_mode)
  defp mode_enabled?("deep"), do: ProductFeatures.enabled?(:deep_mode)
  defp mode_enabled?(_mode), do: false

  defp normalize_inputs(inputs) when is_map(inputs) do
    %{
      "notes" => present(inputs["notes"] || inputs[:notes]),
      "urls" => List.wrap(inputs["urls"] || inputs[:urls]),
      "files" => List.wrap(inputs["files"] || inputs[:files])
    }
  end

  defp normalize_inputs(_inputs), do: %{"notes" => nil, "urls" => [], "files" => []}

  defp derive_title(question) do
    question
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim_trailing("?")
    |> truncate_words(64)
    |> case do
      "" -> "Untitled simulation"
      title -> title
    end
  end

  defp copy_title(title, "ru"), do: truncate_words("Копия · #{title}", 180)
  defp copy_title(title, _locale), do: truncate_words("Copy · #{title}", 180)

  defp truncate_words(text, max) when byte_size(text) <= max, do: text

  defp truncate_words(text, max) do
    shortened = String.slice(text, 0, max - 1)

    shortened
    |> String.split()
    |> Enum.drop(-1)
    |> Enum.join(" ")
    |> case do
      "" -> shortened
      words -> words
    end
    |> Kernel.<>("…")
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp normalize_optional_id(nil), do: nil
  defp normalize_optional_id(value), do: normalize_id(value)

  defp normalize_historical_cutoff(nil), do: {:ok, nil}
  defp normalize_historical_cutoff(""), do: {:ok, nil}

  defp normalize_historical_cutoff(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, :invalid_historical_cutoff}
    end
  end

  defp normalize_historical_cutoff(_value), do: {:error, :invalid_historical_cutoff}

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> -1
    end
  end

  defp normalize_id(_value), do: -1

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
