defmodule HydraAgent.SimLab.Research.PublicUrlFetcher do
  @moduledoc """
  Fetches a researcher-supplied public HTTPS source without requiring a search
  provider. URL validation fails closed: credentials, redirects, local hosts,
  and private-network addresses are rejected before content is stored.
  """

  @max_bytes 1_000_000

  def fetch(url, opts \\ %{})

  def fetch(url, opts) when is_binary(url) do
    opts = Map.new(opts)
    resolver = Map.get(opts, :resolver, &resolve_host/1)
    requester = Map.get(opts, :requester, &Req.get/1)

    with {:ok, uri} <- parse_public_url(url),
         {:ok, address} <- public_address(uri.host, resolver),
         {:ok, response} <-
           requester.(
             url: pinned_url(uri, address),
             redirect: false,
             receive_timeout: 8_000,
             connect_options: [hostname: uri.host, timeout: 5_000],
             into: &bounded_body/2,
             headers: [
               {"host", uri.host},
               {"accept", "text/html, text/plain, text/markdown;q=0.9"}
             ]
           ),
         :ok <- successful_text_response?(response),
         {:ok, body} <- response_body(response) do
      {:ok,
       %{
         uri: URI.to_string(uri),
         title: title(response, body, uri.host),
         text: extract_text(body)
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :unavailable_source}
    end
  end

  def fetch(_url, _opts), do: {:error, :invalid_url}

  defp parse_public_url(url) do
    with {:ok, uri} <- URI.new(String.trim(url)),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         true <- not ip_literal?(uri.host) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_public_https_url}
    end
  end

  defp public_address(host, resolver) do
    with {:ok, addresses} <- resolver.(host),
         true <- addresses != [] and Enum.all?(addresses, &public_address?/1) do
      {:ok, hd(addresses)}
    else
      _ -> {:error, :non_public_host}
    end
  end

  defp resolve_host(host) do
    hostname = String.to_charlist(host)

    ipv4 =
      case :inet.getaddrs(hostname, :inet) do
        {:ok, values} -> values
        _ -> []
      end

    ipv6 =
      case :inet.getaddrs(hostname, :inet6) do
        {:ok, values} -> values
        _ -> []
      end

    case Enum.uniq(ipv4 ++ ipv6) do
      [] -> {:error, :unresolvable_host}
      addresses -> {:ok, addresses}
    end
  end

  defp public_address?({10, _, _, _}), do: false
  defp public_address?({127, _, _, _}), do: false
  defp public_address?({169, 254, _, _}), do: false
  defp public_address?({172, second, _, _}) when second in 16..31, do: false
  defp public_address?({192, 168, _, _}), do: false
  defp public_address?({100, second, _, _}) when second in 64..127, do: false
  defp public_address?({192, 0, _, _}), do: false
  defp public_address?({198, second, _, _}) when second in 18..19, do: false
  defp public_address?({198, 51, 100, _}), do: false
  defp public_address?({203, 0, 113, _}), do: false
  defp public_address?({first, _, _, _}) when first >= 224, do: false
  defp public_address?({0, _, _, _}), do: false
  defp public_address?({_, _, _, _}), do: true
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_address?({0, 0, 0, 0, 0, 65_535, _, _}), do: false
  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: false
  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: false
  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: false
  defp public_address?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false
  defp public_address?({_, _, _, _, _, _, _, _}), do: true
  defp public_address?(_address), do: false

  defp ip_literal?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      _ -> false
    end
  end

  defp pinned_url(uri, address) do
    %{uri | host: address |> :inet.ntoa() |> to_string()} |> URI.to_string()
  end

  defp successful_text_response?(%{status: status, headers: headers}) when status in 200..299 do
    content_type =
      headers
      |> Enum.find_value(fn
        {key, value} when is_binary(key) ->
          if String.downcase(key) == "content-type", do: value

        _ ->
          nil
      end)
      |> to_string()
      |> String.downcase()

    if content_type == "" or String.starts_with?(content_type, "text/"),
      do: :ok,
      else: {:error, :unsupported_content_type}
  end

  defp successful_text_response?(_response), do: {:error, :unavailable_source}

  defp bounded_body({:data, data}, {request, response}) do
    {size, chunks} =
      case response.body do
        {:bounded_body, size, chunks} -> {size, chunks}
        _initial_body -> {0, []}
      end

    next_size = size + byte_size(data)

    if next_size <= @max_bytes do
      {:cont, {request, %{response | body: {:bounded_body, next_size, [data | chunks]}}}}
    else
      {:halt, {request, %{response | body: :source_too_large}}}
    end
  end

  defp response_body(%{body: :source_too_large}), do: {:error, :source_too_large}

  defp response_body(%{body: {:bounded_body, _size, chunks}}) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp response_body(%{body: body}) when is_binary(body) and byte_size(body) <= @max_bytes,
    do: {:ok, body}

  defp response_body(%{body: body}) when is_binary(body), do: {:error, :source_too_large}
  defp response_body(_response), do: {:error, :unreadable_source}

  defp title(response, body, fallback) do
    response.headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "x-title", do: value

      _ ->
        nil
    end)
    |> case do
      title when is_binary(title) and title != "" -> String.slice(title, 0, 180)
      _ -> html_title(body) || fallback
    end
  end

  defp html_title(body) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body, capture: :all_but_first) do
      [title] -> title |> extract_text() |> String.slice(0, 180)
      _ -> nil
    end
  end

  defp extract_text(body) do
    body
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 10_000)
  end
end
