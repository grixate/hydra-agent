defmodule HydraAgent.Providers.OpenAICompatible do
  @behaviour HydraAgent.Provider

  alias HydraAgent.Secrets

  @default_base_url "https://api.openai.com/v1"

  @impl true
  def chat(provider, request) do
    provider
    |> request(:post, "/chat/completions", %{
      model: request["model"] || provider.model,
      messages: request["messages"] || [],
      temperature: request["temperature"],
      max_tokens: request["max_tokens"]
    })
    |> normalize_chat_response(provider)
  end

  @impl true
  def stream_chat(provider, request, callback) do
    # Streaming transport will be upgraded to SSE. For v1, keep the provider
    # contract stable and emit one final delta from the non-streaming response.
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
    |> request(:post, "/embeddings", %{
      model: request["model"] || embedding_model(provider),
      input: request["input"] || ""
    })
    |> normalize_embedding_response(provider)
  end

  @impl true
  def models(provider) do
    provider
    |> request(:get, "/models")
    |> case do
      {:ok, %{"data" => data}} ->
        {:ok, Enum.map(data, &Map.take(&1, ["id", "created", "owned_by"]))}

      {:ok, body} ->
        {:ok, List.wrap(body["data"] || [])}

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
    with {:ok, api_key} <- api_key(provider) do
      url = base_url(provider) <> path

      req =
        [
          method: method,
          url: url,
          headers: [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}],
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
  end

  defp normalize_chat_response({:ok, body}, provider) do
    message =
      body
      |> get_in(["choices"])
      |> List.wrap()
      |> List.first()
      |> case do
        %{"message" => message} -> message
        _ -> %{"role" => "assistant", "content" => ""}
      end

    {:ok,
     %{
       "provider" => provider.name,
       "model" => body["model"] || provider.model,
       "message" => message,
       "usage" => normalize_usage(body["usage"] || %{})
     }}
  end

  defp normalize_chat_response({:error, error}, _provider), do: {:error, error}

  defp normalize_embedding_response({:ok, body}, provider) do
    embeddings =
      body
      |> Map.get("data", [])
      |> Enum.map(&Map.get(&1, "embedding", []))

    {:ok,
     %{
       "provider" => provider.name,
       "model" => body["model"] || embedding_model(provider),
       "embeddings" => embeddings,
       "usage" => normalize_usage(body["usage"] || %{})
     }}
  end

  defp normalize_embedding_response({:error, error}, _provider), do: {:error, error}

  defp normalize_usage(usage) do
    %{
      "input_tokens" => usage["prompt_tokens"] || usage["input_tokens"] || 0,
      "output_tokens" => usage["completion_tokens"] || usage["output_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0
    }
  end

  defp maybe_put_json(req, nil), do: req
  defp maybe_put_json(req, body), do: Keyword.put(req, :json, reject_nil_values(body))

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp base_url(provider), do: String.trim_trailing(provider.base_url || @default_base_url, "/")

  defp embedding_model(provider),
    do: provider.metadata["embedding_model"] || "text-embedding-3-small"

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "" do
    Secrets.fetch_env(env)
  end

  defp api_key(_provider), do: {:error, %{"reason" => "missing_secret_env"}}
end
