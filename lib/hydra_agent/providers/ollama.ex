defmodule HydraAgent.Providers.Ollama do
  @behaviour HydraAgent.Provider

  @default_base_url "http://localhost:11434"

  @impl true
  def chat(provider, request) do
    with :ok <- validate_request_size(request) do
      provider
      |> request(:post, "/api/chat", %{
        model: request["model"] || provider.model,
        messages: request["messages"] || [],
        stream: false,
        options: request["options"] || %{}
      })
      |> normalize_chat_response(provider)
    end
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
        receive_timeout: provider.metadata["receive_timeout_ms"] || 60_000,
        retry: false,
        redirect: false,
        compressed: false
      ]
      |> maybe_put_json(body)
      |> Keyword.merge(test_req_options(provider))

    case Req.request(req) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, provider_http_error(status, response_body)}

      {:error, _error} ->
        {:error, %{"reason" => "provider_request_failed"}}
    end
  rescue
    _error -> {:error, %{"reason" => "provider_request_failed"}}
  end

  defp normalize_chat_response({:ok, body}, provider) do
    with %{"content" => content} = message when is_binary(content) <- body["message"],
         true <- String.valid?(content),
         {:ok, usage} <- normalize_usage(body) do
      {:ok,
       %{
         "provider" => provider.name,
         "model" => body["model"] || provider.model,
         "message" => %{"role" => message["role"] || "assistant", "content" => content},
         "usage" => usage
       }}
    else
      _invalid -> {:error, %{"reason" => "invalid_provider_response"}}
    end
  end

  defp normalize_chat_response({:error, error}, _provider), do: {:error, error}

  defp maybe_put_json(req, nil), do: req
  defp maybe_put_json(req, body), do: Keyword.put(req, :json, body)

  defp normalize_usage(%{"prompt_eval_count" => input, "eval_count" => output})
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    {:ok,
     %{
       "input_tokens" => input,
       "output_tokens" => output,
       "total_tokens" => input + output
     }}
  end

  defp normalize_usage(_body), do: {:error, :invalid_usage}

  defp validate_request_size(request) when is_map(request) do
    if :erlang.iolist_size(Jason.encode_to_iodata!(request)) <= 2_000_000,
      do: :ok,
      else: {:error, %{"reason" => "provider_request_too_large"}}
  rescue
    _error -> {:error, %{"reason" => "invalid_provider_request"}}
  end

  defp validate_request_size(_request), do: {:error, %{"reason" => "invalid_provider_request"}}

  defp provider_http_error(status, body) do
    message = if is_map(body), do: bounded_string(body["error"], 500)

    %{"reason" => "provider_http_error", "status" => status}
    |> maybe_put("provider_message", message)
  end

  defp bounded_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded_string(_value, _maximum), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_url(provider), do: String.trim_trailing(provider.base_url || @default_base_url, "/")

  defp test_req_options(%{metadata: %{req_options: options}}) when is_list(options), do: options

  defp test_req_options(%{metadata: %{"req_options" => options}}) when is_list(options),
    do: options

  defp test_req_options(_provider), do: []
end
