defmodule HydraAgentWeb.SimulationInput do
  @moduledoc "Normalizes bounded, inert composer inputs before persistence."

  @max_files 5
  @max_file_bytes 1_000_000
  @max_total_file_bytes 2_000_000
  @max_notes_bytes 20_000
  @max_urls 10
  @allowed_extensions ~w(.txt .md .markdown .csv .json)

  def limits do
    %{
      files: @max_files,
      per_file_bytes: @max_file_bytes,
      total_file_bytes: @max_total_file_bytes,
      notes_bytes: @max_notes_bytes,
      urls: @max_urls,
      extensions: @allowed_extensions
    }
  end

  def normalize(params) when is_map(params) do
    params = stringify_keys(params)
    notes = params["notes"] |> to_string() |> String.trim()

    with :ok <- validate_notes(notes),
         {:ok, urls} <- normalize_urls(params["urls"] || ""),
         {:ok, files} <- normalize_uploads(params["files"] || []) do
      {:ok,
       params
       |> Map.drop(["files", "urls", "notes"])
       |> Map.put("inputs", %{
         "notes" => if(notes == "", do: nil, else: notes),
         "urls" => urls,
         "files" => files
       })}
    end
  end

  def normalize(_params), do: {:error, :invalid_input}

  defp validate_notes(notes) do
    if byte_size(notes) <= @max_notes_bytes, do: :ok, else: {:error, :notes_too_large}
  end

  defp normalize_urls(value) do
    urls =
      value
      |> to_string()
      |> String.split(~r/[\r\n]+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(urls) > @max_urls ->
        {:error, :too_many_urls}

      true ->
        Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, normalized} ->
          case normalize_public_url(url) do
            {:ok, value} -> {:cont, {:ok, [value | normalized]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          error -> error
        end
    end
  end

  defp normalize_public_url(url) when byte_size(url) <= 2_000 do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme == "https",
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.port) or uri.port == 443,
         true <- public_hostname?(uri.host) do
      normalized = %{uri | host: String.downcase(uri.host), port: nil, fragment: nil}
      {:ok, %{"uri" => URI.to_string(normalized), "status" => "pending"}}
    else
      _ -> {:error, :invalid_public_url}
    end
  end

  defp normalize_public_url(_url), do: {:error, :invalid_public_url}

  defp public_hostname?(host) do
    downcased = String.downcase(host)

    String.contains?(downcased, ".") and
      downcased not in ["localhost", "localhost.localdomain"] and
      not Enum.any?(~w(.local .localhost .internal .lan), &String.ends_with?(downcased, &1)) and
      match?({:error, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp normalize_uploads(value) do
    uploads =
      value
      |> List.wrap()
      |> Enum.filter(&match?(%Plug.Upload{}, &1))

    if length(uploads) > @max_files do
      {:error, :too_many_files}
    else
      uploads
      |> Enum.reduce_while({:ok, [], 0}, fn upload, {:ok, files, total} ->
        case read_upload(upload, total) do
          {:ok, file, next_total} -> {:cont, {:ok, [file | files], next_total}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files, _total} -> {:ok, Enum.reverse(files)}
        error -> error
      end
    end
  end

  # Plug creates and owns `path`; clients control only filename and content.
  # The path is never persisted or exposed, and all stored content is inert UTF-8 text.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_upload(%Plug.Upload{} = upload, current_total) do
    filename = Path.basename(upload.filename)
    extension = filename |> Path.extname() |> String.downcase()

    with true <- extension in @allowed_extensions,
         {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(upload.path),
         true <- current_total + size <= @max_total_file_bytes,
         {:ok, content} <- File.read(upload.path),
         true <- String.valid?(content) and not String.contains?(content, <<0>>),
         :ok <- validate_structured_file(extension, content) do
      {:ok,
       %{
         "filename" => filename,
         "extension" => extension,
         "media_type" => media_type(extension),
         "size_bytes" => size,
         "sha256" => sha256(content),
         "text" => content
       }, current_total + size}
    else
      false -> {:error, :invalid_file}
      {:ok, %{size: _size}} -> {:error, :file_too_large}
      {:error, _reason} -> {:error, :invalid_file}
    end
  end

  defp validate_structured_file(".json", content) do
    case Jason.decode(content) do
      {:ok, _value} -> :ok
      {:error, _reason} -> {:error, :invalid_json_file}
    end
  end

  defp validate_structured_file(_extension, _content), do: :ok

  defp media_type(extension) when extension in [".md", ".markdown"], do: "text/markdown"
  defp media_type(".csv"), do: "text/csv"
  defp media_type(".json"), do: "application/json"
  defp media_type(_extension), do: "text/plain"

  defp sha256(content) do
    content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp stringify_keys(%Plug.Upload{} = upload), do: upload

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
