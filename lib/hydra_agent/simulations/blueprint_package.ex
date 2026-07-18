defmodule HydraAgent.Simulations.BlueprintPackage do
  @moduledoc "Fail-closed import and deterministic export for `.hydra-blueprint` archives."

  import Bitwise

  alias HydraAgent.Simulations.{BlueprintManifest, BlueprintVersion}

  @max_archive_bytes 2_000_000
  @max_uncompressed_bytes 10_000_000
  @max_file_bytes 2_000_000
  @max_entries 80
  @root "blueprint/"
  @required_files [
    "blueprint.yaml",
    "instructions/research.md",
    "instructions/agents.md",
    "instructions/simulation.md",
    "instructions/report.md",
    "schemas/context-pack.schema.json",
    "schemas/population-model.schema.json",
    "schemas/simulation-script.schema.json",
    "schemas/observation-plan.schema.json",
    "schemas/report.schema.json",
    "README.md"
  ]
  @executable_extensions ~w(.beam .ex .exs .eex .heex .js .mjs .cjs .ts .sh .bash .zsh .fish .py .rb .pl .php .jar .class .dll .so .dylib .exe .com .bat .cmd .ps1 .app .apk)
  @fixed_zip_time {{2020, 1, 1}, {0, 0, 0}}

  def limits do
    %{
      compressed_bytes: @max_archive_bytes,
      uncompressed_bytes: @max_uncompressed_bytes,
      per_file_bytes: @max_file_bytes,
      entries: @max_entries
    }
  end

  def import(binary) when is_binary(binary) do
    with :ok <- validate_compressed_size(binary),
         :ok <- validate_central_directory(binary),
         {:ok, table} <- zip_table(binary),
         :ok <- validate_entries(table),
         {:ok, files} <- extract(binary),
         :ok <- validate_extracted_files(files),
         {:ok, package} <- build_package(files) do
      {:ok, package}
    end
  end

  def import(_), do: error(:invalid_archive, "Blueprint archive must be binary data")

  def from_components(components) when is_map(components) do
    manifest = stringify_keys(components[:manifest] || components["manifest"] || %{})
    instructions = stringify_keys(components[:instructions] || components["instructions"] || %{})
    schemas = stringify_keys(components[:schemas] || components["schemas"] || %{})
    examples = stringify_keys(components[:examples] || components["examples"] || %{})
    readme = components[:readme] || components["readme"] || ""

    files =
      %{"blueprint.yaml" => BlueprintManifest.encode(manifest), "README.md" => readme}
      |> add_instruction_files(manifest, instructions)
      |> add_schema_files(schemas)
      |> add_example_files(examples)

    build_package(files)
  end

  def export(%BlueprintVersion{} = version) do
    export(%{
      manifest: version.manifest,
      instructions: version.instructions,
      schemas: version.schemas,
      examples: version.examples,
      readme: version.readme
    })
  end

  def export(package) when is_map(package) do
    manifest = stringify_keys(package[:manifest] || package["manifest"] || %{})
    instructions = stringify_keys(package[:instructions] || package["instructions"] || %{})
    schemas = stringify_keys(package[:schemas] || package["schemas"] || %{})
    examples = stringify_keys(package[:examples] || package["examples"] || %{})
    readme = package[:readme] || package["readme"] || ""

    base_files =
      %{"README.md" => readme}
      |> add_instruction_files(manifest, instructions)
      |> add_schema_files(schemas)
      |> add_example_files(examples)

    declared_hashes =
      base_files
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new(fn {path, content} -> {path, "sha256:" <> sha256(content)} end)

    manifest = Map.put(manifest, "files", declared_hashes)
    files = Map.put(base_files, "blueprint.yaml", BlueprintManifest.encode(manifest))

    with {:ok, normalized} <- build_package(files),
         {:ok, {_name, binary}} <- create_zip(files) do
      filename =
        normalized.manifest["id"] <> "-" <> normalized.manifest["version"] <> ".hydra-blueprint"

      {:ok, %{filename: filename, binary: binary, content_hash: normalized.content_hash}}
    else
      {:error, _reason} = error -> error
      other -> error(:export_failed, "Blueprint archive could not be created", other)
    end
  end

  def content_hash(package) do
    semantic = %{
      "manifest" =>
        package.manifest
        |> Map.drop(["files", "content_hash", "imported_origin"]),
      "instructions" => package.instructions,
      "schemas" => package.schemas,
      "examples" => package.examples,
      "readme" => package.readme
    }

    semantic |> canonical() |> sha256()
  end

  defp validate_compressed_size(binary) do
    if byte_size(binary) <= @max_archive_bytes,
      do: :ok,
      else: error(:archive_too_large, "Compressed Blueprint archive exceeds the 2 MB limit")
  end

  defp validate_central_directory(binary) do
    with {:ok, %{offset: offset, size: size, entries: entries}} <-
           end_of_central_directory(binary),
         true <- offset + size <= byte_size(binary),
         central <- binary_part(binary, offset, size),
         :ok <- validate_central_entries(central, entries) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> error(:invalid_archive, "Blueprint archive has an invalid central directory")
    end
  end

  defp end_of_central_directory(binary) do
    :binary.matches(binary, <<0x06054B50::little-32>>)
    |> Enum.reverse()
    |> Enum.find_value(fn {position, _length} -> parse_eocd_at(binary, position) end)
    |> case do
      nil -> error(:invalid_archive, "Blueprint archive has no end-of-directory record")
      record -> {:ok, record}
    end
  end

  defp parse_eocd_at(binary, position) do
    available = byte_size(binary) - position

    if available >= 22 do
      <<_prefix::binary-size(position), 0x06054B50::little-32, disk::little-16,
        central_disk::little-16, disk_entries::little-16, entries::little-16,
        central_size::little-32, central_offset::little-32, comment_size::little-16,
        _rest::binary>> = binary

      if disk == 0 and central_disk == 0 and disk_entries == entries and
           position + 22 + comment_size == byte_size(binary) do
        %{offset: central_offset, size: central_size, entries: entries}
      end
    end
  end

  defp validate_central_entries(<<>>, 0), do: :ok

  defp validate_central_entries(
         <<0x02014B50::little-32, _made_by::little-16, _needed::little-16, flags::little-16,
           method::little-16, _time::little-16, _date::little-16, _crc::little-32,
           compressed_size::little-32, uncompressed_size::little-32, path_size::little-16,
           extra_size::little-16, comment_size::little-16, _disk::little-16, _internal::little-16,
           external::little-32, _offset::little-32, path::binary-size(path_size),
           _extra::binary-size(extra_size), _comment::binary-size(comment_size), rest::binary>>,
         entries
       )
       when entries > 0 do
    unix_mode = external >>> 16
    file_type = band(unix_mode, 0o170000)

    cond do
      band(flags, 0x1) != 0 ->
        error(:encrypted_archive, "Encrypted Blueprint archives are not supported")

      method not in [0, 8] ->
        error(:unsupported_compression, "Blueprint archive uses unsupported compression", method)

      compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF ->
        error(:unsupported_zip64, "ZIP64 Blueprint archives are not supported")

      file_type not in [0, 0o040000, 0o100000] ->
        error(:unsafe_file_type, "Symlinks and special files are not allowed", %{
          path: path,
          mode: unix_mode
        })

      true ->
        validate_central_entries(rest, entries - 1)
    end
  end

  defp validate_central_entries(_central, _entries) do
    error(:invalid_archive, "Blueprint archive has malformed central-directory entries")
  end

  defp zip_table(binary) do
    case :zip.table(binary) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> error(:invalid_archive, "Blueprint archive is not a valid ZIP", reason)
    end
  rescue
    exception -> error(:invalid_archive, "Blueprint archive could not be inspected", exception)
  catch
    kind, reason ->
      error(:invalid_archive, "Blueprint archive could not be inspected", {kind, reason})
  end

  defp validate_entries(table) do
    entries = Enum.reject(table, &match?({:zip_comment, _}, &1))

    cond do
      length(entries) > @max_entries ->
        error(:too_many_files, "Blueprint archive contains more than #{@max_entries} entries")

      true ->
        validate_entry_list(entries, MapSet.new(), 0)
    end
  end

  defp validate_entry_list([], _seen, total) when total <= @max_uncompressed_bytes, do: :ok

  defp validate_entry_list([], _seen, _total) do
    error(:archive_too_large, "Uncompressed Blueprint archive exceeds the 10 MB limit")
  end

  defp validate_entry_list(
         [{:zip_file, raw_name, file_info, _comment, _offset, compressed_size} | rest],
         seen,
         total
       ) do
    stat = File.Stat.from_record(file_info)

    with {:ok, path} <- normalize_archive_path(raw_name),
         :ok <- validate_entry_type(path, stat),
         :ok <- validate_entry_sizes(stat.size, compressed_size),
         :ok <- reject_duplicate(path, seen),
         :ok <- reject_executable_path(path, stat.mode) do
      validate_entry_list(rest, MapSet.put(seen, path), total + stat.size)
    end
  end

  defp validate_entry_list([_unknown | _rest], _seen, _total) do
    error(:invalid_archive, "Blueprint archive contains an unsupported ZIP entry")
  end

  defp normalize_archive_path(raw_name) do
    with {:ok, name} <- to_utf8(raw_name) do
      path = String.replace(name, "\\", "/")
      segments = String.split(path, "/", trim: false)

      cond do
        path == "" or String.contains?(path, <<0>>) ->
          error(:unsafe_path, "Blueprint archive contains an empty or invalid path")

        String.starts_with?(path, "/") or Regex.match?(~r/^[A-Za-z]:\//, path) ->
          error(:unsafe_path, "Blueprint archive contains an absolute path", path)

        ".." in segments or "." in segments ->
          error(:unsafe_path, "Blueprint archive contains path traversal", path)

        not String.starts_with?(path, @root) ->
          error(:unsafe_path, "Every Blueprint file must be inside blueprint/", path)

        true ->
          {:ok, path}
      end
    end
  end

  defp to_utf8(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) ->
        if String.valid?(binary),
          do: {:ok, binary},
          else: error(:invalid_filename, "Blueprint archive contains a non-UTF-8 filename")

      _ ->
        error(:invalid_filename, "Blueprint archive contains a non-UTF-8 filename")
    end
  rescue
    _ -> error(:invalid_filename, "Blueprint archive contains a non-UTF-8 filename")
  end

  defp to_utf8(name) when is_binary(name) do
    if String.valid?(name),
      do: {:ok, name},
      else: error(:invalid_filename, "Blueprint archive contains a non-UTF-8 filename")
  end

  defp to_utf8(_), do: error(:invalid_filename, "Blueprint archive contains an invalid filename")

  defp validate_entry_type(path, %File.Stat{type: type, mode: mode}) do
    cond do
      is_integer(mode) and band(mode, 0o170000) == 0o120000 ->
        error(:unsafe_file_type, "Symlinks and special files are not allowed", %{
          path: path,
          type: :symlink
        })

      type == :directory and String.ends_with?(path, "/") ->
        :ok

      type == :directory ->
        error(:unsafe_file_type, "Directory entry has an invalid path", path)

      type == :regular ->
        :ok

      true ->
        error(:unsafe_file_type, "Symlinks and special files are not allowed", %{
          path: path,
          type: type
        })
    end
  end

  defp validate_entry_sizes(size, compressed_size)
       when is_integer(size) and size >= 0 and is_integer(compressed_size) and
              compressed_size >= 0 do
    if size <= @max_file_bytes,
      do: :ok,
      else: error(:file_too_large, "A Blueprint file exceeds the 2 MB limit")
  end

  defp validate_entry_sizes(_size, _compressed_size) do
    error(:invalid_archive, "Blueprint archive contains invalid file sizes")
  end

  defp reject_duplicate(path, seen) do
    if MapSet.member?(seen, path),
      do: error(:duplicate_path, "Blueprint archive contains a duplicate path", path),
      else: :ok
  end

  defp reject_executable_path(path, mode) do
    extension = path |> Path.extname() |> String.downcase()
    executable_mode = is_integer(mode) and band(mode, 0o111) != 0

    if extension in @executable_extensions or executable_mode,
      do: error(:executable_file, "Executable files are not allowed in a Blueprint", path),
      else: :ok
  end

  defp extract(binary) do
    case :zip.extract(binary, [:memory]) do
      {:ok, entries} ->
        entries
        |> Enum.reduce_while({:ok, %{}}, fn {raw_name, content}, {:ok, files} ->
          with {:ok, full_path} <- normalize_archive_path(raw_name) do
            relative = String.replace_prefix(full_path, @root, "")

            if relative == "" or String.ends_with?(relative, "/") do
              {:cont, {:ok, files}}
            else
              {:cont, {:ok, Map.put(files, relative, IO.iodata_to_binary(content))}}
            end
          else
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, reason} ->
        error(:invalid_archive, "Blueprint archive could not be decompressed", reason)
    end
  rescue
    exception -> error(:invalid_archive, "Blueprint archive could not be decompressed", exception)
  catch
    kind, reason ->
      error(:invalid_archive, "Blueprint archive could not be decompressed", {kind, reason})
  end

  defp validate_extracted_files(files) do
    total = Enum.reduce(files, 0, fn {_path, content}, acc -> acc + byte_size(content) end)

    cond do
      total > @max_uncompressed_bytes ->
        error(:archive_too_large, "Uncompressed Blueprint archive exceeds the 10 MB limit")

      Enum.any?(files, fn {_path, content} -> byte_size(content) > @max_file_bytes end) ->
        error(:file_too_large, "A Blueprint file exceeds the 2 MB limit")

      Enum.any?(files, fn {_path, content} -> executable_magic?(content) end) ->
        error(:executable_file, "Executable file content is not allowed in a Blueprint")

      true ->
        :ok
    end
  end

  defp executable_magic?(<<0x7F, "ELF", _::binary>>), do: true
  defp executable_magic?(<<"MZ", _::binary>>), do: true
  defp executable_magic?(<<"#!", _::binary>>), do: true
  defp executable_magic?(_), do: false

  defp build_package(files) do
    available = files |> Map.keys() |> MapSet.new()
    missing = @required_files -- MapSet.to_list(available)

    if missing != [] do
      error(:missing_files, "Blueprint package is incomplete", missing)
    else
      with {:ok, manifest} <- BlueprintManifest.parse(files["blueprint.yaml"]),
           {:ok, warnings} <- BlueprintManifest.validate(manifest, available),
           :ok <- validate_declared_hashes(manifest, files),
           {:ok, instructions} <- load_instructions(manifest, files),
           {:ok, schemas} <- load_schemas(files),
           :ok <- validate_schema_references(schemas) do
        package = %{
          manifest: manifest,
          instructions: instructions,
          schemas: schemas,
          examples: load_examples(files),
          readme: files["README.md"],
          compatibility_warnings: warnings,
          validation_errors: []
        }

        {:ok, Map.put(package, :content_hash, content_hash(package))}
      else
        {:error, errors, warnings} ->
          error(:invalid_manifest, "Blueprint manifest validation failed", %{
            errors: errors,
            warnings: warnings
          })

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp validate_declared_hashes(manifest, files) do
    case manifest["files"] || %{} do
      hashes when is_map(hashes) ->
        Enum.reduce_while(hashes, :ok, fn {path, declared}, :ok ->
          expected = files[path]

          cond do
            not is_binary(expected) ->
              {:halt,
               error(:hash_target_missing, "A declared hash references a missing file", path)}

            normalize_declared_hash(declared) != sha256(expected) ->
              {:halt, error(:hash_mismatch, "A Blueprint file hash does not match", path)}

            true ->
              {:cont, :ok}
          end
        end)

      _ ->
        error(:invalid_hashes, "Manifest files must be a map of SHA-256 hashes")
    end
  end

  defp normalize_declared_hash("sha256:" <> hash), do: String.downcase(hash)
  defp normalize_declared_hash(hash) when is_binary(hash), do: String.downcase(hash)
  defp normalize_declared_hash(_), do: ""

  defp load_instructions(manifest, files) do
    BlueprintManifest.modules()
    |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, acc} ->
      path = get_in(manifest, ["modules", module, "instructions"])
      content = files[path]

      cond do
        not is_binary(content) ->
          {:halt, error(:missing_instruction, "An instruction module is missing", module)}

        not String.valid?(content) or String.contains?(content, <<0>>) ->
          {:halt,
           error(:invalid_instruction, "Instruction modules must be valid UTF-8 text", module)}

        String.length(String.trim(content)) < 20 ->
          {:halt, error(:invalid_instruction, "Instruction module is too short", module)}

        true ->
          {:cont, {:ok, Map.put(acc, module, content)}}
      end
    end)
  end

  defp load_schemas(files) do
    files
    |> Enum.filter(fn {path, _content} ->
      String.starts_with?(path, "schemas/") and String.ends_with?(path, ".schema.json")
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {path, content}, {:ok, acc} ->
      case Jason.decode(content) do
        {:ok, schema} when is_map(schema) ->
          if valid_schema_document?(schema) do
            {:cont, {:ok, Map.put(acc, path, schema)}}
          else
            {:halt, error(:invalid_schema, "JSON Schema is missing an object contract", path)}
          end

        _ ->
          {:halt, error(:invalid_schema, "Schema file is not a valid JSON object", path)}
      end
    end)
  end

  defp valid_schema_document?(schema) do
    is_binary(schema["$id"] || "") and schema["type"] in ["object", "array"] and
      is_map(schema["properties"] || %{})
  end

  defp validate_schema_references(schemas) do
    case Enum.find(schemas, fn {_path, schema} -> unsafe_ref?(schema) end) do
      nil ->
        :ok

      {path, _schema} ->
        error(:unsafe_schema_reference, "External schema references are not allowed", path)
    end
  end

  defp unsafe_ref?(%{"$ref" => ref}) when is_binary(ref), do: not String.starts_with?(ref, "#")

  defp unsafe_ref?(map) when is_map(map),
    do: Enum.any?(map, fn {_key, value} -> unsafe_ref?(value) end)

  defp unsafe_ref?(list) when is_list(list), do: Enum.any?(list, &unsafe_ref?/1)
  defp unsafe_ref?(_), do: false

  defp load_examples(files) do
    files
    |> Enum.filter(fn {path, _content} -> String.starts_with?(path, "examples/") end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp add_instruction_files(files, manifest, instructions) do
    Enum.reduce(BlueprintManifest.modules(), files, fn module, acc ->
      path = get_in(manifest, ["modules", module, "instructions"])
      content = instructions[module]

      if is_binary(path) and is_binary(content), do: Map.put(acc, path, content), else: acc
    end)
  end

  defp add_schema_files(files, schemas) do
    Enum.reduce(schemas, files, fn {path, schema}, acc ->
      path = String.replace_prefix(path, "blueprint/", "")

      content =
        cond do
          is_map(schema) or is_list(schema) -> Jason.encode!(schema, pretty: true)
          is_binary(schema) -> schema
        end

      if is_binary(content),
        do: Map.put(acc, path, content <> trailing_newline(content)),
        else: acc
    end)
  end

  defp add_example_files(files, examples) do
    Enum.reduce(examples, files, fn {path, content}, acc ->
      path = String.replace_prefix(path, "blueprint/", "")
      content = if is_binary(content), do: content, else: Jason.encode!(content, pretty: true)
      Map.put(acc, path, content)
    end)
  end

  defp trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: "", else: "\n"
  end

  defp create_zip(files) do
    entries =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {relative, content} ->
        path = String.to_charlist(@root <> relative)

        stat =
          %File.Stat{
            size: byte_size(content),
            type: :regular,
            access: :read_write,
            atime: @fixed_zip_time,
            mtime: @fixed_zip_time,
            ctime: @fixed_zip_time,
            mode: 0o644,
            links: 1,
            major_device: 0,
            minor_device: 0,
            inode: 0,
            uid: 0,
            gid: 0
          }
          |> File.Stat.to_record()

        {path, content, stat}
      end)

    :zip.create(~c"blueprint.hydra-blueprint", entries, [:memory])
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, nested} -> Jason.encode!(key) <> ":" <> canonical(nested) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical(value) when is_list(value) do
    value |> Enum.map_join(",", &canonical/1) |> then(&("[" <> &1 <> "]"))
  end

  defp canonical(value), do: Jason.encode!(value)

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp error(code, message, detail \\ nil) do
    {:error, %{code: code, message: message, detail: detail}}
  end
end
