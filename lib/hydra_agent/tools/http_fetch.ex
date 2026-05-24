defmodule HydraAgent.Tools.HttpFetch do
  @behaviour HydraAgent.Tool

  @impl true
  def spec do
    %{
      name: "http_fetch",
      side_effect_class: "network",
      timeout_ms: 20_000,
      approval_sensitive: true,
      description: "Fetch an HTTP or HTTPS URL allowed by the tool policy.",
      input_schema: %{
        "type" => "object",
        "required" => ["url"],
        "properties" => %{
          "url" => %{"type" => "string"},
          "method" => %{"type" => "string", "enum" => ["GET", "HEAD"]},
          "max_bytes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000_000}
        }
      },
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "status" => %{"type" => "integer"},
          "headers" => %{"type" => "object"},
          "body" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"}
        }
      }
    }
  end

  @impl true
  def execute(input, _context) do
    input = stringify_keys(input || %{})
    url = input["url"]
    method = input["method"] || "GET"
    max_bytes = input["max_bytes"] || 200_000

    with :ok <- validate_url(url),
         :ok <- validate_method(method),
         {:ok, response} <- request(method, url) do
      body = normalize_body(response.body)
      {body, truncated?} = truncate(body, max_bytes)

      {:ok,
       %{
         "url" => url,
         "status" => response.status,
         "headers" => headers_map(response.headers),
         "body" => body,
         "truncated" => truncated?
       }}
    end
  end

  defp request(method, url) do
    method_atom = method |> String.downcase() |> String.to_existing_atom()

    case Req.request(method: method_atom, url: url, receive_timeout: 15_000) do
      {:ok, response} ->
        {:ok, response}

      {:error, error} ->
        {:error, %{"reason" => "http_fetch_failed", "error" => Exception.message(error)}}
    end
  rescue
    ArgumentError -> {:error, %{"reason" => "unsupported_method", "method" => method}}
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      :ok
    else
      {:error, %{"reason" => "invalid_http_url"}}
    end
  end

  defp validate_url(_url), do: {:error, %{"reason" => "url_required"}}

  defp validate_method(method) when method in ["GET", "HEAD"], do: :ok

  defp validate_method(method),
    do: {:error, %{"reason" => "unsupported_method", "method" => method}}

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body), do: Jason.encode!(body)

  defp truncate(body, max_bytes) when byte_size(body) > max_bytes do
    {binary_part(body, 0, max_bytes), true}
  end

  defp truncate(body, _max_bytes), do: {body, false}

  defp headers_map(headers) do
    Map.new(headers, fn {key, values} -> {key, Enum.join(List.wrap(values), ", ")} end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
