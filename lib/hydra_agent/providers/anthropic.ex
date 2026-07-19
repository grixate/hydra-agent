defmodule HydraAgent.Providers.Anthropic do
  @behaviour HydraAgent.Provider

  alias HydraAgent.Secrets

  @default_base_url "https://api.anthropic.com/v1"
  @version "2023-06-01"

  @impl true
  def chat(provider, request) do
    with :ok <- validate_request_size(request) do
      provider
      |> request(:post, "/messages", %{
        model: request["model"] || provider.model,
        messages: request["messages"] || [],
        system: request["system"],
        max_tokens: request["max_tokens"] || 1024,
        temperature: request["temperature"]
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
  def embed(_provider, _request), do: {:error, %{"reason" => "embeddings_not_supported"}}

  @impl true
  def models(provider), do: {:ok, [%{"id" => provider.model, "provider" => provider.name}]}

  @impl true
  def health(provider) do
    case api_key(provider) do
      {:ok, _api_key} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp request(provider, method, path, body) do
    with {:ok, api_key} <- api_key(provider) do
      options =
        [
          method: method,
          url: base_url(provider) <> path,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", provider.metadata["anthropic_version"] || @version},
            {"content-type", "application/json"}
          ],
          json: reject_nil_values(body),
          receive_timeout: provider.metadata["receive_timeout_ms"] || 60_000,
          retry: false,
          redirect: false,
          compressed: false
        ]
        |> Keyword.merge(test_req_options(provider))

      case Req.request(options) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: status, body: response_body}} ->
          {:error, provider_http_error(status, response_body)}

        {:error, _error} ->
          {:error, %{"reason" => "provider_request_failed"}}
      end
    end
  rescue
    _error -> {:error, %{"reason" => "provider_request_failed"}}
  end

  defp normalize_chat_response({:ok, body}, provider) do
    with content_parts when is_list(content_parts) <- body["content"],
         {:ok, content} <- text_content(content_parts),
         {:ok, usage} <- normalize_usage(body["usage"]) do
      {:ok,
       %{
         "provider" => provider.name,
         "model" => body["model"] || provider.model,
         "request_id" => bounded_string(body["id"], 200),
         "message" => %{"role" => "assistant", "content" => content},
         "usage" => usage
       }
       |> reject_nil_values()}
    else
      _invalid -> {:error, %{"reason" => "invalid_provider_response"}}
    end
  end

  defp normalize_chat_response({:error, error}, _provider), do: {:error, error}

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp text_content(parts) do
    text =
      Enum.map_join(parts, "", fn
        %{"type" => "text", "text" => text} when is_binary(text) -> text
        _part -> ""
      end)

    if String.valid?(text), do: {:ok, text}, else: {:error, :invalid_content}
  end

  defp normalize_usage(%{"input_tokens" => input, "output_tokens" => output})
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    {:ok,
     %{
       "input_tokens" => input,
       "output_tokens" => output,
       "total_tokens" => input + output
     }}
  end

  defp normalize_usage(_usage), do: {:error, :invalid_usage}

  defp validate_request_size(request) when is_map(request) do
    if :erlang.iolist_size(Jason.encode_to_iodata!(request)) <= 2_000_000,
      do: :ok,
      else: {:error, %{"reason" => "provider_request_too_large"}}
  rescue
    _error -> {:error, %{"reason" => "invalid_provider_request"}}
  end

  defp validate_request_size(_request), do: {:error, %{"reason" => "invalid_provider_request"}}

  defp provider_http_error(status, body) do
    vendor = if is_map(body), do: body["error"], else: nil

    %{"reason" => "provider_http_error", "status" => status}
    |> maybe_put("provider_type", vendor_value(vendor, "type"))
    |> maybe_put("provider_message", vendor_value(vendor, "message"))
  end

  defp vendor_value(map, key) when is_map(map), do: bounded_string(map[key], 500)
  defp vendor_value(_map, _key), do: nil

  defp bounded_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded_string(_value, _maximum), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_url(provider), do: String.trim_trailing(provider.base_url || @default_base_url, "/")

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "" do
    Secrets.fetch_env(env)
  end

  defp api_key(_provider), do: {:error, %{"reason" => "missing_secret_env"}}

  defp test_req_options(%{metadata: %{req_options: options}}) when is_list(options), do: options

  defp test_req_options(%{metadata: %{"req_options" => options}}) when is_list(options),
    do: options

  defp test_req_options(_provider), do: []
end
