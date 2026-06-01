defmodule HydraAgent.Providers.OpenAICompatible do
  @behaviour HydraAgent.Provider

  alias HydraAgent.Providers.OpenAICompatible.Stream
  alias HydraAgent.Secrets

  @default_base_url "https://api.openai.com/v1"
  @stream_private_key :hydra_openai_stream

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
    provider
    |> stream_request(
      %{
        model: request["model"] || provider.model,
        messages: request["messages"] || [],
        temperature: request["temperature"],
        max_tokens: request["max_tokens"],
        stream: true,
        stream_options: %{"include_usage" => true}
      },
      callback
    )
    |> normalize_stream_response(provider)
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

  defp stream_request(provider, body, callback) when is_function(callback, 1) do
    with {:ok, api_key} <- api_key(provider) do
      url = base_url(provider) <> "/chat/completions"
      initial_state = Stream.new(provider)

      req =
        [
          method: :post,
          url: url,
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"},
            {"accept", "text/event-stream"}
          ],
          json: reject_nil_values(body),
          receive_timeout: provider.metadata["receive_timeout_ms"] || 60_000,
          into: stream_into(callback, initial_state)
        ]
        |> Keyword.merge(test_req_options(provider))

      case Req.request(req) do
        {:ok, %{status: status, private: private}} when status in 200..299 ->
          {state, errors} = stream_state(private, initial_state)
          {state, events} = Stream.finish(state)
          {new_errors, events} = split_stream_errors(events)
          errors = errors ++ new_errors

          case errors do
            [] ->
              Enum.each(events, callback)
              {:ok, Stream.response(state, provider)}

            errors ->
              {:error, %{"reason" => "invalid_sse_stream", "stream_errors" => errors}}
          end

        {:ok, %{status: status, private: private}} ->
          {_state, errors} = stream_state(private, initial_state)

          {:error,
           %{
             "reason" => "provider_http_error",
             "status" => status,
             "stream_errors" => errors
           }}

        {:error, error} ->
          {:error, %{"reason" => "provider_request_failed", "error" => Exception.message(error)}}
      end
    end
  end

  defp stream_into(callback, initial_state) do
    fn {:data, data}, {request, response} ->
      {state, previous_errors} =
        Map.get(response.private, @stream_private_key, {initial_state, []})

      {state, events} = Stream.parse_chunk(state, data)
      {new_errors, events} = split_stream_errors(events)

      Enum.each(events, callback)

      response =
        put_in(response.private[@stream_private_key], {state, previous_errors ++ new_errors})

      {:cont, {request, response}}
    end
  end

  defp stream_state(private, initial_state) do
    case Map.get(private, @stream_private_key) do
      {state, errors} -> {state, errors}
      _missing -> {initial_state, []}
    end
  end

  defp split_stream_errors(events) do
    Enum.split_with(events, fn event -> event["type"] == "message.error" end)
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
  defp normalize_stream_response({:ok, response}, _provider), do: {:ok, response}
  defp normalize_stream_response({:error, error}, _provider), do: {:error, error}

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

  defp test_req_options(%{metadata: %{req_options: options}}) when is_list(options), do: options

  defp test_req_options(%{metadata: %{"req_options" => options}}) when is_list(options),
    do: options

  defp test_req_options(_provider), do: []
end
