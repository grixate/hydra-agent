defmodule HydraAgent.Simulations.ManualExternalModel do
  @moduledoc "Bounded request/export contract for disconnected external-model generation."

  alias HydraAgent.Simulations.{
    ContentHash,
    ContextPack,
    PopulationModel,
    PortableArchive,
    Simulation
  }

  @protocol_version 1
  @max_upload_bytes 5_000_000

  def limits, do: %{upload_bytes: @max_upload_bytes}

  def request(%Simulation{} = simulation) do
    version = simulation.active_version
    blueprint = simulation.selected_blueprint.active_version

    modules =
      ~w(research agents simulation)
      |> Enum.map(fn module ->
        schema_path = get_in(blueprint.manifest, ["modules", module, "output_schema"])

        %{
          "module" => module,
          "instructions" => blueprint.instructions[module],
          "output_schema_path" => schema_path,
          "output_schema" => blueprint.schemas[schema_path],
          "preceding_artifact" => preceding_artifact(simulation, module)
        }
      end)

    request = %{
      "hydra_manual_request" => @protocol_version,
      "simulation_version_hash" => version.content_hash,
      "blueprint" => %{
        "id" => simulation.selected_blueprint.slug,
        "version" => blueprint.version,
        "content_hash" => blueprint.content_hash
      },
      "base_artifact_hashes" => base_artifact_hashes(simulation),
      "input" => %{
        "question" => version.question,
        "locale" => version.locale,
        "population_size" => version.population_size,
        "execution_mode" => version.execution_mode,
        "variables" => version.normalized_input,
        "raw_sources_included" => false,
        "source_manifest" => source_manifest(version.inputs)
      },
      "modules" => modules,
      "expected_upload" => %{
        "hydra_manual_artifacts" => @protocol_version,
        "simulation_version_hash" => version.content_hash,
        "blueprint_version_hash" => blueprint.content_hash,
        "base_artifact_hashes" => base_artifact_hashes(simulation),
        "context_pack" => "JSON matching the research output schema",
        "population_model" => "JSON matching the agents output schema",
        "simulation_script" => "JSON matching the simulation output schema"
      },
      "instructions" => [
        "Run the modules in order: research, agents, simulation.",
        "Pass each validated JSON result into the next module as the preceding artifact.",
        "Return JSON only. Do not add executable code, templates, or provider credentials.",
        "Keep every identifier from the provided preceding artifacts unless the schema requires a new one.",
        "Assemble the three results in the expected_upload object and upload that JSON to Hydra."
      ],
      "privacy" => %{
        "raw_sources" => "excluded",
        "provider_credentials" => "excluded"
      }
    }

    request = Map.put(request, "content_hash", ContentHash.digest(request))

    {:ok,
     %{
       binary: PortableArchive.json(request),
       filename: "hydra-manual-request-#{String.slice(version.content_hash, 0, 10)}.json",
       content_hash: request["content_hash"]
     }}
  end

  def parse(binary) when is_binary(binary) and byte_size(binary) <= @max_upload_bytes do
    with {:ok, bundle} when is_map(bundle) <- Jason.decode(binary),
         :ok <- validate_bundle(bundle) do
      {:ok, bundle}
    else
      {:error, %Jason.DecodeError{} = error} ->
        failure(
          :invalid_json,
          "External-model upload is not valid JSON",
          Exception.message(error)
        )

      {:error, _reason} = error ->
        error

      _ ->
        failure(:invalid_bundle, "External-model upload must contain a JSON object")
    end
  end

  def parse(binary) when is_binary(binary),
    do: failure(:upload_too_large, "External-model upload exceeds the 5 MB limit")

  def parse(_binary), do: failure(:invalid_upload, "External-model upload must be binary JSON")

  defp validate_bundle(bundle) do
    cond do
      bundle["hydra_manual_artifacts"] != @protocol_version ->
        failure(
          :unsupported_manual_format,
          "This upload uses an unsupported manual-artifact format. Export a new request from this Hydra deployment."
        )

      not is_binary(bundle["simulation_version_hash"]) ->
        failure(:missing_version_hash, "External-model upload is missing Simulation lineage")

      not is_binary(bundle["blueprint_version_hash"]) ->
        failure(:missing_blueprint_hash, "External-model upload is missing Blueprint lineage")

      not is_map(bundle["base_artifact_hashes"]) ->
        failure(:missing_artifact_hashes, "External-model upload is missing artifact lineage")

      not is_map(bundle["context_pack"]) ->
        failure(:missing_context_output, "External-model upload is missing context_pack JSON")

      not is_map(bundle["population_model"]) ->
        failure(
          :missing_population_output,
          "External-model upload is missing population_model JSON"
        )

      not is_map(bundle["simulation_script"]) ->
        failure(:missing_script_output, "External-model upload is missing simulation_script JSON")

      true ->
        :ok
    end
  end

  defp preceding_artifact(simulation, "research") do
    %{
      "question" => simulation.active_version.question,
      "scope" => simulation.active_context_pack && simulation.active_context_pack.scope,
      "source_manifest" => source_manifest(simulation.active_version.inputs)
    }
  end

  defp preceding_artifact(simulation, "agents") do
    context = simulation.active_context_pack
    if context, do: ContextPack.schema_payload(context), else: nil
  end

  defp preceding_artifact(simulation, "simulation") do
    population = simulation.active_population_model

    if population do
      PopulationModel.schema_payload(PopulationModel.contract(population))
    end
  end

  defp preceding_artifact(_simulation, _module), do: nil

  defp source_manifest(inputs) do
    inputs = inputs || %{}

    %{
      "notes_present" => is_binary(inputs["notes"]),
      "urls" =>
        Enum.map(inputs["urls"] || [], fn source ->
          %{"uri" => source["uri"], "status" => source["status"]}
        end),
      "files" =>
        Enum.map(inputs["files"] || [], fn file ->
          Map.take(file, ~w(filename extension media_type size_bytes sha256))
        end)
    }
  end

  defp base_artifact_hashes(simulation) do
    %{
      "context_pack" =>
        simulation.active_context_pack && simulation.active_context_pack.content_hash,
      "population_model" =>
        simulation.active_population_model && simulation.active_population_model.content_hash,
      "simulation_script" => simulation.active_script && simulation.active_script.content_hash
    }
  end

  defp failure(code, message, detail \\ nil),
    do: {:error, %{code: code, message: message, detail: detail}}
end
