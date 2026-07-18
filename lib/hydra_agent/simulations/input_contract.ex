defmodule HydraAgent.Simulations.InputContract do
  @moduledoc "Fail-closed semantic validation for immutable Simulation Version inputs."

  @max_files 5
  @max_file_bytes 1_000_000
  @max_total_file_bytes 2_000_000
  @max_notes_bytes 20_000
  @max_urls 10
  @allowed_extensions ~w(.txt .md .markdown .csv .json)

  def validate(inputs) when is_map(inputs) do
    notes = inputs["notes"] || inputs[:notes]
    urls = inputs["urls"] || inputs[:urls] || []
    files = inputs["files"] || inputs[:files] || []

    with :ok <- validate_notes(notes),
         :ok <- validate_urls(urls),
         :ok <- validate_files(files) do
      {:ok, %{"notes" => notes, "urls" => urls, "files" => files}}
    end
  end

  def validate(_inputs), do: {:error, :invalid_inputs}

  defp validate_notes(nil), do: :ok

  defp validate_notes(notes) when is_binary(notes) and byte_size(notes) <= @max_notes_bytes do
    if String.valid?(notes) and not String.contains?(notes, <<0>>),
      do: :ok,
      else: {:error, :invalid_notes}
  end

  defp validate_notes(_notes), do: {:error, :invalid_notes}

  defp validate_urls(urls) when is_list(urls) and length(urls) <= @max_urls do
    if Enum.all?(urls, &valid_url_entry?/1), do: :ok, else: {:error, :invalid_public_url}
  end

  defp validate_urls(_urls), do: {:error, :too_many_urls}

  defp valid_url_entry?(%{"uri" => url, "status" => "pending"}) when is_binary(url) do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.fragment),
         true <- public_hostname?(uri.host) do
      true
    else
      _ -> false
    end
  end

  defp valid_url_entry?(_entry), do: false

  defp public_hostname?(host) do
    downcased = String.downcase(host)

    downcased not in ["localhost", "localhost.localdomain"] and
      not String.ends_with?(downcased, ".localhost") and
      match?({:error, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp validate_files(files) when is_list(files) and length(files) <= @max_files do
    with true <- Enum.all?(files, &valid_file_entry?/1),
         total when total <= @max_total_file_bytes <-
           Enum.reduce(files, 0, &(&2 + &1["size_bytes"])) do
      :ok
    else
      false -> {:error, :invalid_file}
      _total -> {:error, :file_too_large}
    end
  end

  defp validate_files(_files), do: {:error, :too_many_files}

  defp valid_file_entry?(%{
         "filename" => filename,
         "extension" => extension,
         "media_type" => media_type,
         "size_bytes" => size,
         "sha256" => hash,
         "text" => text
       }) do
    is_binary(filename) and filename == Path.basename(filename) and filename != "" and
      is_binary(extension) and extension in @allowed_extensions and
      String.downcase(Path.extname(filename)) == extension and
      media_type == media_type(extension) and
      is_integer(size) and size >= 0 and size <= @max_file_bytes and
      is_binary(text) and byte_size(text) == size and String.valid?(text) and
      not String.contains?(text, <<0>>) and hash == sha256(text) and
      valid_structured_content?(extension, text)
  end

  defp valid_file_entry?(_entry), do: false

  defp valid_structured_content?(".json", text), do: match?({:ok, _value}, Jason.decode(text))
  defp valid_structured_content?(_extension, _text), do: true

  defp media_type(extension) when extension in [".md", ".markdown"], do: "text/markdown"
  defp media_type(".csv"), do: "text/csv"
  defp media_type(".json"), do: "application/json"
  defp media_type(_extension), do: "text/plain"

  defp sha256(content) do
    content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
