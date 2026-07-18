defmodule HydraAgent.Security.PublicEndpoint do
  @moduledoc """
  Validates and DNS-pins operator-configured outbound HTTPS endpoints.

  Every resolved address must be public. Callers must disable redirects so a
  validated public endpoint cannot redirect into a private network.
  """

  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    resolver = Keyword.get(opts, :resolver, &resolve_host/1)

    with {:ok, uri} <- URI.new(String.trim(url)),
         :ok <- validate_uri(uri),
         {:ok, addresses} <- resolver.(uri.host),
         true <- addresses != [] and Enum.all?(addresses, &public_address?/1) do
      address = hd(addresses)

      {:ok,
       %{
         uri: uri,
         original_url: URI.to_string(uri),
         pinned_url: %{uri | host: address |> :inet.ntoa() |> to_string()} |> URI.to_string(),
         host: uri.host,
         connect_options: [hostname: uri.host, timeout: 5_000]
       }}
    else
      false -> {:error, :non_public_host}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_public_https_url}
    end
  end

  def validate(_url, _opts), do: {:error, :invalid_public_https_url}

  defp validate_uri(%URI{} = uri) do
    cond do
      uri.scheme != "https" -> {:error, :invalid_public_https_url}
      not is_binary(uri.host) or uri.host == "" -> {:error, :invalid_public_https_url}
      not is_nil(uri.userinfo) -> {:error, :invalid_public_https_url}
      ip_literal?(uri.host) -> {:error, :ip_literal_not_allowed}
      true -> :ok
    end
  end

  defp resolve_host(host) do
    hostname = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(hostname, family) do
          {:ok, values} -> values
          _ -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :unresolvable_host}, else: {:ok, addresses}
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
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end
end
