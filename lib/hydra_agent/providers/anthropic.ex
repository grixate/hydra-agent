defmodule HydraAgent.Providers.Anthropic do
  @behaviour HydraAgent.Provider

  alias HydraAgent.Secrets

  @default_base_url "https://api.anthropic.com/v1"
  @version "2023-06-01"

  @impl true
  def chat(provider, request) do
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
      case Req.request(
             method: method,
             url: base_url(provider) <> path,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", provider.metadata["anthropic_version"] || @version},
               {"content-type", "application/json"}
             ],
             json: reject_nil_values(body),
             receive_timeout: provider.metadata["receive_timeout_ms"] || 60_000
           ) do
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
    content =
      body
      |> Map.get("content", [])
      |> Enum.map_join("", fn
        %{"type" => "text", "text" => text} -> text
        _part -> ""
      end)

    usage = body["usage"] || %{}

    {:ok,
     %{
       "provider" => provider.name,
       "model" => body["model"] || provider.model,
       "message" => %{"role" => "assistant", "content" => content},
       "usage" => %{
         "input_tokens" => usage["input_tokens"] || 0,
         "output_tokens" => usage["output_tokens"] || 0,
         "total_tokens" => (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
       }
     }}
  end

  defp normalize_chat_response({:error, error}, _provider), do: {:error, error}

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp base_url(provider), do: String.trim_trailing(provider.base_url || @default_base_url, "/")

  defp api_key(%{api_key_env: env}) when is_binary(env) and env != "" do
    Secrets.fetch_env(env)
  end

  defp api_key(_provider), do: {:error, %{"reason" => "missing_secret_env"}}
end
