defmodule HydraAgent.Redaction do
  @moduledoc """
  Small recursive redaction helpers for audit, safety, and trace payloads.
  """

  @sensitive_key_fragments ~w(secret token api_key apikey key password passphrase authorization bearer credential)
  @max_string_bytes 500

  def redact(value), do: do_redact(value)

  defp do_redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, do_redact(value)}
      end
    end)
  end

  defp do_redact(list) when is_list(list), do: Enum.map(list, &do_redact/1)

  defp do_redact(value) when is_binary(value) and byte_size(value) > @max_string_bytes do
    binary_part(value, 0, @max_string_bytes) <> "...[TRUNCATED]"
  end

  defp do_redact(value), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_key_fragments, &String.contains?(key, &1))
  end
end
