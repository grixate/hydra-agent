defmodule HydraAgent.Providers.Ollama do
  @behaviour HydraAgent.Provider

  @default_base_url "http://localhost:11434"

  @impl true
  def chat(provider, request) do
    provider
    |> request(:post, "/api/chat", %{
      model: request["model"] || provider.model,
      messages: request["messages"] || [],
      stream: false,
      options: request["options"] || %{}
    })
    |> normalize_chat_response(provider)
  end

  @impl true
  def stream_chat(provider, request, callback) do
    case chat(provider, request) do
      {:ok, response} ->
        callback.(%{
          "type" => "message.delta",
          "content" => get_in(response, ["message", "content"]) || ""
        })

        {:ok, response}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def embed(provider, request) do
    provider
    |> request(:post, "/api/embed", %{
      model: request["model"] || provider.metadata["embedding_model"] || provider.model,
      input: request["input"] || ""
    })
    |> case do
      {:ok, body} ->
        {:ok,
         %{
           "provider" => provider.name,
           "model" => body["model"] || provider.model,
           "embeddings" => body["embeddings"] || []
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def models(provider) do
    provider
    |> request(:get, "/api/tags")
    |> case do
      {:ok, %{"models" => models}} ->
        {:ok, Enum.map(models, &Map.take(&1, ["name", "model", "modified_at", "size"]))}

      {:ok, body} ->
        {:ok, List.wrap(body["models"] || [])}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def health(provider) do
    case models(provider) do
      {:ok, _models} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp request(provider, method, path, body \\ nil) do
    req =
      [
        method: method,
        url: base_url(provider) <> path,
        receive_timeout: provider.metadata["receive_timeout_ms"] || 60_000
      ]
      |> maybe_put_json(body)

    case Req.request(req) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error,
         %{"reason" => "provider_http_error", "status" => status, "body" => response_body}}

      {:error, error} ->
        {:error, %{"reason" => "provider_request_failed", "error" => Exception.message(error)}}
    end
  end

  defp normalize_chat_response({:ok, body}, provider) do
    {:ok,
     %{
       "provider" => provider.name,
       "model" => body["model"] || provider.model,
       "message" => body["message"] || %{"role" => "assistant", "content" => ""},
       "usage" => %{
         "input_tokens" => body["prompt_eval_count"] || 0,
         "output_tokens" => body["eval_count"] || 0,
         "total_tokens" => (body["prompt_eval_count"] || 0) + (body["eval_count"] || 0)
       }
     }}
  end

  defp normalize_chat_response({:error, error}, _provider), do: {:error, error}

  defp maybe_put_json(req, nil), do: req
  defp maybe_put_json(req, body), do: Keyword.put(req, :json, body)
  defp base_url(provider), do: String.trim_trailing(provider.base_url || @default_base_url, "/")
end
