defmodule HydraAgent.Providers.Mock do
  @behaviour HydraAgent.Provider

  @impl true
  def chat(provider, request) do
    text =
      request
      |> Map.get("messages", [])
      |> List.last()
      |> case do
        %{"content" => content} -> content
        %{content: content} -> content
        _ -> "ok"
      end

    {:ok,
     %{
       "provider" => provider.name,
       "model" => provider.model,
       "message" => %{"role" => "assistant", "content" => "mock: #{text}"},
       "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
     }}
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
end
