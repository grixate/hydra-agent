defmodule HydraAgent.Security.BoundedJsonHttp do
  @moduledoc """
  Performs a bounded JSON request to an operator-configured public HTTPS endpoint.

  The endpoint is validated and DNS-pinned before the request. Redirects and
  automatic retries remain disabled so the validated destination cannot change
  after validation. Response bodies are streamed into a fixed-size accumulator
  before JSON decoding.
  """

  alias HydraAgent.Security.PublicEndpoint

  @max_bytes 1_000_000

  def request(method, endpoint, request_options, opts \\ [])

  def request(method, endpoint, request_options, opts)
      when method in [:get, :post] and is_list(request_options) and is_list(opts) do
    requester = Keyword.get(opts, :requester) || default_requester(method)
    validation_options = validation_options(opts)

    with true <- is_function(requester, 1),
         {:ok, target} <- PublicEndpoint.validate(endpoint, validation_options),
         {:ok, response} <- requester.(secure_options(target, request_options)),
         {:ok, body} <- bounded_response_body(response) do
      {:ok, %{response | body: body}}
    else
      false -> {:error, :invalid_http_requester}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_http_response}
    end
  end

  def request(_method, _endpoint, _request_options, _opts),
    do: {:error, :invalid_http_request}

  def decode_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> {:ok, body}
      {:ok, _encoded} -> {:error, :response_too_large}
      {:error, _reason} -> {:error, :invalid_json_response}
    end
  end

  def decode_body(body) when is_binary(body) and byte_size(body) <= @max_bytes do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json_response}
    end
  end

  def decode_body(body) when is_binary(body), do: {:error, :response_too_large}
  def decode_body(_body), do: {:error, :invalid_json_response}

  defp validation_options(opts) do
    case Keyword.get(opts, :resolver) do
      resolver when is_function(resolver, 1) -> [resolver: resolver]
      _ -> []
    end
  end

  defp secure_options(target, request_options) do
    headers =
      request_options
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn
        {key, _value} when is_binary(key) -> String.downcase(key) in ["host", "accept-encoding"]
        _ -> false
      end)

    request_options
    |> Keyword.put(:url, target.pinned_url)
    |> Keyword.put(:headers, [
      {"host", host_header(target.uri)},
      {"accept-encoding", "identity"}
      | headers
    ])
    |> Keyword.put(:connect_options, target.connect_options)
    |> Keyword.put(:redirect, false)
    |> Keyword.put(:retry, false)
    |> Keyword.put(:compressed, false)
    |> Keyword.put(:decode_body, false)
    |> Keyword.put(:into, &bounded_body/2)
  end

  defp host_header(%URI{host: host, port: port, scheme: "https"})
       when is_integer(port) and port != 443,
       do: "#{host}:#{port}"

  defp host_header(%URI{host: host}), do: host

  defp bounded_body({:data, data}, {request, response}) when is_binary(data) do
    {size, chunks} =
      case response.body do
        {:bounded_json_body, size, chunks} -> {size, chunks}
        _initial_body -> {0, []}
      end

    next_size = size + byte_size(data)

    if next_size <= @max_bytes do
      {:cont, {request, %{response | body: {:bounded_json_body, next_size, [data | chunks]}}}}
    else
      {:halt, {request, %{response | body: :response_too_large}}}
    end
  end

  defp bounded_response_body(%{body: :response_too_large}),
    do: {:error, :response_too_large}

  defp bounded_response_body(%{body: {:bounded_json_body, _size, chunks}}) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp bounded_response_body(%{body: body})
       when is_binary(body) and byte_size(body) <= @max_bytes,
       do: {:ok, body}

  defp bounded_response_body(%{body: body}) when is_binary(body),
    do: {:error, :response_too_large}

  defp bounded_response_body(%{body: body}) when is_map(body) do
    case decode_body(body) do
      {:ok, _decoded} -> {:ok, body}
      {:error, _reason} = error -> error
    end
  end

  defp bounded_response_body(_response), do: {:error, :invalid_http_response}

  defp default_requester(:get), do: &Req.get/1
  defp default_requester(:post), do: &Req.post/1
end
