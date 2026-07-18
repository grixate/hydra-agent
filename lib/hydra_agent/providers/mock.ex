defmodule HydraAgent.Providers.Mock do
  @behaviour HydraAgent.Provider

  @impl true
  def chat(provider, request) do
    if simulation_request?(request) and provider.metadata["mock_simulation_response"] == "error" do
      {:error, %{"reason" => "mock_provider_failure"}}
    else
      {text, usage} = mock_content(provider, request)

      {:ok,
       %{
         "provider" => provider.name,
         "model" => provider.model,
         "message" => %{"role" => "assistant", "content" => text},
         "usage" => usage
       }}
    end
  end

  @impl true
  def stream_chat(provider, request, callback) do
    {:ok, response} = chat(provider, request)
    callback.(%{"type" => "message.delta", "content" => response["message"]["content"]})
    {:ok, response}
  end

  @impl true
  def embed(provider, request) do
    inputs = List.wrap(request["input"] || "")

    {:ok,
     %{
       "provider" => provider.name,
       "model" => provider.model,
       "embeddings" => Enum.map(inputs, fn _ -> List.duplicate(0.0, 8) end)
     }}
  end

  @impl true
  def models(provider), do: {:ok, [%{"id" => provider.model, "provider" => provider.name}]}

  @impl true
  def health(_provider), do: :ok

  defp mock_content(
         %{metadata: %{"mock_simulation_response" => "invalid"}},
         %{"metadata" => %{"hydra_simulation_decision" => true}}
       ),
       do: {"not-json", %{"input_tokens" => 4, "output_tokens" => 2}}

  defp mock_content(_provider, %{"metadata" => %{"hydra_simulation_decision" => true}} = request) do
    allowed = get_in(request, ["metadata", "allowed_actions"]) || ["observe"]
    decision_key = get_in(request, ["metadata", "decision_key"]) || ""
    index = if allowed == [], do: 0, else: :erlang.phash2(decision_key, length(allowed))
    action_id = Enum.at(allowed, index) || "observe"

    payload = %{
      "action_id" => action_id,
      "parameters" => %{},
      "reason_codes" => ["representative_policy"],
      "short_rationale" => "Selected from the allowed actions for this policy signature.",
      "memory_updates" => %{},
      "uncertainty" => 0.25
    }

    {Jason.encode!(payload), %{"input_tokens" => 24, "output_tokens" => 32}}
  end

  defp mock_content(_provider, request) do
    text =
      request
      |> Map.get("messages", [])
      |> List.last()
      |> case do
        %{"content" => content} -> content
        %{content: content} -> content
        _ -> "ok"
      end

    {"mock: #{text}", %{"input_tokens" => 0, "output_tokens" => 0}}
  end

  defp simulation_request?(request),
    do: get_in(request, ["metadata", "hydra_simulation_decision"]) == true
end
