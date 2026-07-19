defmodule HydraAgent.ProviderStaging do
  @moduledoc "Opt-in, low-cost staging probe for one configured production provider route."

  alias HydraAgent.Providers
  alias HydraAgent.Runtime.ProviderConfig

  @supported_kinds ~w(openai_compatible anthropic ollama)

  def probe(%ProviderConfig{kind: kind} = provider) when kind in @supported_kinds do
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    started_at = System.monotonic_time(:millisecond)
    request = request(provider, nonce)

    try do
      case Providers.chat(provider, request) do
        {:ok, response} ->
          validate_response(provider, response, nonce, elapsed(started_at))

        {:error, error} ->
          {:error, failure_report(provider, error, elapsed(started_at))}
      end
    rescue
      _error ->
        {:error,
         failure_report(
           provider,
           %{"reason" => "provider_probe_exception"},
           elapsed(started_at)
         )}
    end
  end

  def probe(%ProviderConfig{} = provider) do
    {:error, failure_report(provider, %{"reason" => "unsupported_staging_provider"}, 0)}
  end

  defp validate_response(provider, response, nonce, elapsed_ms) do
    content = get_in(response, ["message", "content"])
    usage = response["usage"]

    with true <- is_binary(content),
         {:ok, decoded} <- Jason.decode(content),
         true <- decoded == %{"status" => "ok", "nonce" => nonce},
         true <- valid_usage?(usage) do
      {:ok,
       %{
         "schema_version" => 1,
         "status" => "passed",
         "provider" => provider.name,
         "kind" => provider.kind,
         "model" => response["model"] || provider.model,
         "request_id" => bounded_string(response["request_id"], 200),
         "elapsed_ms" => elapsed_ms,
         "usage" => Map.take(usage, ~w(input_tokens output_tokens total_tokens)),
         "checks" => %{
           "authentication" => "passed",
           "structured_output" => "passed",
           "usage_accounting" => "passed",
           "bounded_request" => "passed"
         }
       }
       |> reject_nil_values()}
    else
      _invalid ->
        {:error, failure_report(provider, %{"reason" => "invalid_staging_response"}, elapsed_ms)}
    end
  end

  defp request(provider, nonce) do
    instruction =
      "Return one JSON object only with exactly two string fields: status and nonce. Do not use tools, Markdown, or prose."

    user = %{
      "role" => "user",
      "content" => Jason.encode!(%{"status" => "ok", "nonce" => nonce})
    }

    base = %{
      "model" => provider.model,
      "temperature" => 0,
      "max_tokens" => 100,
      "messages" => [%{"role" => "system", "content" => instruction}, user]
    }

    case provider.kind do
      "anthropic" -> Map.merge(base, %{"system" => instruction, "messages" => [user]})
      "ollama" -> Map.put(base, "options", %{"temperature" => 0, "num_predict" => 100})
      _kind -> base
    end
  end

  defp failure_report(provider, error, elapsed_ms) do
    reason = error["reason"] || error[:reason] || "provider_failure"
    status = error["status"] || error[:status]

    %{
      "schema_version" => 1,
      "status" => "failed",
      "classification" => classify(reason, status),
      "reason" => bounded_string(to_string(reason), 120),
      "http_status" => if(is_integer(status), do: status),
      "provider" => provider.name,
      "kind" => provider.kind,
      "model" => provider.model,
      "elapsed_ms" => elapsed_ms
    }
    |> reject_nil_values()
  end

  defp classify("provider_http_error", 401), do: "authentication"
  defp classify("provider_http_error", 403), do: "authorization"
  defp classify("provider_http_error", 429), do: "rate_limit"
  defp classify("provider_request_failed", _status), do: "transport"
  defp classify("missing_secret_env", _status), do: "credential"
  defp classify("invalid_provider_response", _status), do: "response_contract"
  defp classify("invalid_staging_response", _status), do: "response_contract"
  defp classify("provider_request_too_large", _status), do: "request_envelope"
  defp classify("unsupported_staging_provider", _status), do: "unsupported"
  defp classify(_reason, _status), do: "provider"

  defp valid_usage?(usage) when is_map(usage) do
    Enum.all?(~w(input_tokens output_tokens total_tokens), fn key ->
      is_integer(usage[key]) and usage[key] >= 0
    end)
  end

  defp valid_usage?(_usage), do: false

  defp elapsed(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp bounded_string(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp bounded_string(_value, _maximum), do: nil

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
