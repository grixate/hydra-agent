defmodule HydraAgent.Tools.MultiModelConsensus do
  @behaviour HydraAgent.Tool

  alias HydraAgent.Providers

  @impl true
  def spec do
    %{
      name: "multi_model_consensus",
      side_effect_class: "multi_model",
      timeout_ms: 60_000,
      approval_sensitive: true,
      description:
        "Ask multiple configured providers for independent answers and return a synthesis.",
      input_schema: %{"type" => "object", "required" => ["prompt", "providers"]},
      output_schema: %{"type" => "object"}
    }
  end

  @impl true
  def execute(input, context) do
    input = stringify_keys(input || %{})
    workspace_id = context["workspace_id"] || context[:workspace_id]
    prompt = input["prompt"]
    providers = List.wrap(input["providers"])

    cond do
      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, %{"reason" => "consensus_prompt_required"}}

      providers == [] ->
        {:error, %{"reason" => "consensus_providers_required"}}

      true ->
        responses =
          Enum.map(providers, fn provider_name ->
            case Providers.get_config_by_name(workspace_id, provider_name) do
              nil -> %{"provider" => provider_name, "status" => "missing"}
              provider -> provider_response(provider, prompt)
            end
          end)

        {:ok,
         %{
           "responses" => responses,
           "synthesis" => synthesis(responses),
           "ok_count" => Enum.count(responses, &(&1["status"] == "ok"))
         }}
    end
  end

  defp provider_response(provider, prompt) do
    case Providers.chat(provider, %{"messages" => [%{"role" => "user", "content" => prompt}]}) do
      {:ok, response} ->
        %{
          "provider" => provider.name,
          "status" => "ok",
          "content" => get_in(response, ["message", "content"]),
          "usage" => response["usage"] || %{}
        }

      {:error, error} ->
        %{"provider" => provider.name, "status" => "error", "error" => error}
    end
  end

  defp synthesis(responses) do
    responses
    |> Enum.filter(&(&1["status"] == "ok"))
    |> Enum.map(& &1["content"])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
