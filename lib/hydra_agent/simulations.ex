defmodule HydraAgent.Simulations do
  @moduledoc "Durable Blueprint-first Simulation and Simulation Version operations."

  import Ecto.Query

  alias Ecto.Multi

  alias HydraAgent.{Accounts, ProductFeatures, Repo}
  alias HydraAgent.Runtime.Workspace
  alias HydraAgent.SimLab.Schemas.Study

  alias HydraAgent.Simulations.{
    Blueprint,
    Blueprints,
    BuildStage,
    ContentHash,
    InputContract,
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
    |> preload([:active_version, selected_blueprint: :active_version])
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
    |> preload([:workspace, :active_version, selected_blueprint: :active_version])
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
    simulation = Repo.preload(simulation, [:workspace, :active_version, :selected_blueprint])

    attrs = %{
      "title" => copy_title(simulation.title),
      "question" => simulation.active_version.question,
      "locale" => simulation.active_version.locale,
      "blueprint_id" => simulation.selected_blueprint_id,
      "population_size" => simulation.active_version.population_size,
      "execution_mode" => simulation.active_version.execution_mode,
      "budget_preset" => simulation.active_version.budget_preset,
      "geography" => simulation.active_version.normalized_input["geography"],
      "horizon" => simulation.active_version.normalized_input["horizon"],
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
        with {:ok, inputs} <- InputContract.validate(normalize_inputs(attrs["inputs"] || %{})) do
          title = attrs |> Map.get("title") |> present() || derive_title(question)

          normalized_input = %{
            "question" => question,
            "geography" => present(attrs["geography"]),
            "horizon" => present(attrs["horizon"]),
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
      |> Multi.run(:stages, fn repo, %{simulation: simulation, version: version} ->
        insert_initial_stages(repo, workspace.id, simulation.id, version.id)
      end)
      |> Multi.run(:activated, fn repo, %{simulation: simulation, version: version} ->
        simulation |> Simulation.activate_changeset(version) |> repo.update()
      end)

    case Repo.transaction(multi) do
      {:ok, %{activated: simulation}} ->
        {:ok,
         Repo.preload(simulation, [
           :workspace,
           :active_version,
           selected_blueprint: :active_version
         ])}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp insert_initial_stages(repo, workspace_id, simulation_id, version_id) do
    Enum.reduce_while(@stage_definitions, {:ok, []}, fn {stage, ordinal}, {:ok, stages} ->
      changeset =
        BuildStage.changeset(%BuildStage{}, %{
          workspace_id: workspace_id,
          simulation_id: simulation_id,
          simulation_version_id: version_id,
          stage: stage,
          ordinal: ordinal,
          status: "pending",
          warnings: []
        })

      case repo.insert(changeset) do
        {:ok, inserted} -> {:cont, {:ok, [inserted | stages]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp copy_title(title) do
    title
    |> Kernel.<>(" copy")
    |> truncate_words(180)
  end

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
