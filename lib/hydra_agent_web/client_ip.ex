defmodule HydraAgentWeb.ClientIp do
  @moduledoc """
  Resolves a rate-limit identity without trusting caller-controlled proxy headers.

  Forwarded addresses are considered only when the socket peer is an explicitly
  trusted proxy. Loopback peers are trusted by default for the recommended
  same-host reverse-proxy deployment.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @loopbacks [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

  def address(conn) do
    peer = conn.remote_ip

    if trusted_proxy?(peer) do
      forwarded_address(conn) || format(peer)
    else
      format(peer)
    end
  end

  defp forwarded_address(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [header] ->
        header
        |> String.split(",")
        |> Enum.reverse()
        |> Enum.find_value(&parse_forwarded/1)

      _missing_or_ambiguous ->
        nil
    end
  end

  defp parse_forwarded(value) do
    value = String.trim(value)

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> format(address)
      {:error, _reason} -> nil
    end
  end

  defp trusted_proxy?(peer) do
    peer in configured_trusted_proxies()
  end

  defp configured_trusted_proxies do
    :hydra_agent
    |> Application.get_env(:trusted_proxy_ips, @loopbacks)
    |> Enum.flat_map(fn
      address when is_tuple(address) ->
        [address]

      address when is_binary(address) ->
        case :inet.parse_address(String.to_charlist(String.trim(address))) do
          {:ok, parsed} -> [parsed]
          {:error, _reason} -> []
        end

      _invalid ->
        []
    end)
  end

  defp format(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> "unknown"
      value -> IO.iodata_to_binary(value)
    end
  end
end
