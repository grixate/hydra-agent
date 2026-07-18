defmodule HydraAgent.Security.WorkspacePath do
  @moduledoc """
  Fail-closed filesystem helpers for paths beneath a trusted workspace root.

  Lexical `Path.expand/2` checks are not sufficient on their own: an attacker
  can place a symbolic link below the root and make an apparently safe path
  resolve somewhere else. These helpers reject symbolic links in every path
  component, re-check file identity around reads, and use same-directory
  temporary files for writes.
  """

  @type reason :: %{String.t() => term()}

  @spec root(term()) :: {:ok, String.t()} | {:error, reason()}
  def root(value) when is_binary(value) and value != "" do
    expanded = Path.expand(value)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
      {:ok, %File.Stat{type: :symlink}} -> error("workspace_root_is_symlink", expanded)
      {:ok, _stat} -> error("workspace_root_not_directory", expanded)
      {:error, reason} -> file_error("workspace_root_unavailable", expanded, reason)
    end
  end

  def root(_value), do: {:error, %{"reason" => "workspace_root_required"}}

  @spec ensure_root(term()) :: {:ok, String.t()} | {:error, reason()}
  def ensure_root(value) when is_binary(value) and value != "" do
    expanded = Path.expand(value)

    with :ok <- mkdir_p_from_existing_ancestor(expanded) do
      root(expanded)
    end
  end

  def ensure_root(_value), do: {:error, %{"reason" => "workspace_root_required"}}

  @spec resolve(term(), term(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def resolve(root_value, path, opts \\ [])

  def resolve(root_value, path, opts) when is_binary(path) and path != "" do
    kind = Keyword.get(opts, :kind, :any)
    allow_missing? = Keyword.get(opts, :allow_missing, kind == :write)

    with :ok <- validate_path_string(path),
         {:ok, root} <- root(root_value),
         expanded <- Path.expand(path, root),
         :ok <- ensure_lexically_inside(expanded, root),
         {:ok, final_stat} <- inspect_components(root, expanded, allow_missing?),
         :ok <- validate_kind(final_stat, kind, expanded) do
      {:ok, expanded}
    end
  end

  def resolve(_root, _path, _opts), do: {:error, %{"reason" => "path_required"}}

  @spec ensure_parent(term(), term()) :: {:ok, String.t()} | {:error, reason()}
  def ensure_parent(root_value, path) when is_binary(path) do
    with {:ok, root} <- root(root_value),
         expanded <- Path.expand(path, root),
         :ok <- ensure_lexically_inside(expanded, root),
         parent <- Path.dirname(expanded),
         :ok <- mkdir_below_root(root, parent),
         {:ok, ^parent} <- resolve(root, parent, kind: :directory) do
      {:ok, parent}
    end
  end

  @spec read_regular(term(), term()) :: {:ok, binary()} | {:error, reason() | File.Error.t()}
  def read_regular(root_value, path) do
    with {:ok, resolved} <- resolve(root_value, path, kind: :regular),
         {:ok, before} <- File.lstat(resolved),
         {:ok, content} <- File.read(resolved),
         {:ok, after_stat} <- File.lstat(resolved),
         :ok <- ensure_same_file(before, after_stat, resolved) do
      {:ok, content}
    else
      {:error, %File.Error{} = error} ->
        {:error, error}

      {:error, reason} when is_atom(reason) ->
        file_error("file_read_failed", to_string(path), reason)

      error ->
        error
    end
  end

  @spec atomic_write(term(), term(), iodata(), :overwrite | :append | :create_new) ::
          :ok | {:error, reason() | File.Error.t() | atom()}
  def atomic_write(root_value, path, content, mode \\ :overwrite)

  def atomic_write(root_value, path, content, mode)
      when mode in [:overwrite, :append, :create_new] do
    with {:ok, root} <- root(root_value),
         {:ok, resolved} <- resolve(root, path, kind: :write),
         {:ok, parent} <- ensure_parent(root, resolved),
         {:ok, parent_before} <- File.lstat(parent),
         {:ok, payload} <- write_payload(root, resolved, content, mode),
         {:ok, ^resolved} <- resolve(root, resolved, kind: :write),
         {:ok, parent_after} <- File.lstat(parent),
         :ok <- ensure_same_file(parent_before, parent_after, parent),
         :ok <- replace_from_temp(root, resolved, parent, payload, mode) do
      :ok
    end
  end

  def atomic_write(_root, _path, _content, mode),
    do: {:error, %{"reason" => "unsupported_write_mode", "mode" => to_string(mode)}}

  @spec remove(term(), term()) :: :ok | {:error, reason() | atom()}
  def remove(root_value, path) do
    with {:ok, resolved} <- resolve(root_value, path, kind: :write) do
      case File.lstat(resolved) do
        {:ok, %File.Stat{type: :regular}} -> File.rm(resolved)
        {:error, :enoent} -> :ok
        {:ok, %File.Stat{type: :symlink}} -> error("workspace_path_symlink", resolved)
        {:ok, _stat} -> error("workspace_path_not_regular", resolved)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec list_regular_files(term()) :: {:ok, [String.t()]} | {:error, reason()}
  def list_regular_files(root_value) do
    with {:ok, root} <- root(root_value) do
      walk_directory(root, root, [])
    end
  end

  @spec lexically_inside?(term(), term()) :: boolean()
  def lexically_inside?(path, root) when is_binary(path) and is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  def lexically_inside?(_path, _root), do: false

  defp validate_path_string(path) do
    if String.contains?(path, <<0>>),
      do: {:error, %{"reason" => "path_contains_null_byte"}},
      else: :ok
  end

  defp ensure_lexically_inside(path, root) do
    if lexically_inside?(path, root),
      do: :ok,
      else:
        {:error,
         %{"reason" => "path_outside_workspace_root", "path" => path, "workspace_root" => root}}
  end

  defp inspect_components(root, expanded, _allow_missing?) do
    relative = Path.relative_to(expanded, root)
    segments = if relative == ".", do: [], else: Path.split(relative)

    Enum.reduce_while(segments, {:ok, root, %File.Stat{type: :directory}}, fn segment,
                                                                              {:ok, current, _} ->
      candidate = Path.join(current, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, error("workspace_path_symlink", candidate)}

        {:ok, stat} ->
          {:cont, {:ok, candidate, stat}}

        {:error, :enoent} ->
          {:halt, {:ok, candidate, :missing}}

        {:error, reason} ->
          {:halt, file_error("workspace_path_unavailable", candidate, reason)}
      end
    end)
    |> case do
      {:ok, _path, stat} -> {:ok, stat}
      error -> error
    end
  end

  defp validate_kind(:missing, :write, _path), do: :ok
  defp validate_kind(%File.Stat{type: :regular}, :write, _path), do: :ok
  defp validate_kind(%File.Stat{type: :regular}, :regular, _path), do: :ok
  defp validate_kind(%File.Stat{type: :directory}, :directory, _path), do: :ok
  defp validate_kind(_stat, :any, _path), do: :ok
  defp validate_kind(:missing, _kind, path), do: error("workspace_path_missing", path)
  defp validate_kind(_stat, :write, path), do: error("workspace_path_not_regular", path)
  defp validate_kind(_stat, :regular, path), do: error("workspace_path_not_regular", path)
  defp validate_kind(_stat, :directory, path), do: error("workspace_path_not_directory", path)

  defp mkdir_below_root(root, parent) do
    relative = Path.relative_to(parent, root)
    segments = if relative == ".", do: [], else: Path.split(relative)

    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, current} ->
      candidate = Path.join(current, segment)

      result =
        case File.lstat(candidate) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: :symlink}} -> error("workspace_path_symlink", candidate)
          {:ok, _stat} -> error("workspace_path_not_directory", candidate)
          {:error, :enoent} -> create_directory(candidate)
          {:error, reason} -> file_error("workspace_path_unavailable", candidate, reason)
        end

      case result do
        :ok -> {:cont, {:ok, candidate}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end

  defp create_directory(path) do
    case File.mkdir(path) do
      :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: :symlink}} -> error("workspace_path_symlink", path)
          {:ok, _stat} -> error("workspace_path_not_directory", path)
          {:error, reason} -> file_error("workspace_directory_create_failed", path, reason)
        end

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: :symlink}} -> error("workspace_path_symlink", path)
          {:ok, _stat} -> error("workspace_path_not_directory", path)
          {:error, reason} -> file_error("workspace_directory_create_failed", path, reason)
        end

      {:error, reason} ->
        file_error("workspace_directory_create_failed", path, reason)
    end
  end

  defp mkdir_p_from_existing_ancestor(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        error("workspace_root_is_symlink", path)

      {:ok, _stat} ->
        error("workspace_root_not_directory", path)

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          error("workspace_root_unavailable", path)
        else
          with :ok <- mkdir_p_from_existing_ancestor(parent),
               :ok <- create_directory(path) do
            :ok
          end
        end

      {:error, reason} ->
        file_error("workspace_root_unavailable", path, reason)
    end
  end

  defp write_payload(root, resolved, content, :append) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, existing} <- read_regular(root, resolved) do
          {:ok, [existing, content]}
        end

      {:error, :enoent} ->
        {:ok, content}

      {:ok, %File.Stat{type: :symlink}} ->
        error("workspace_path_symlink", resolved)

      {:ok, _stat} ->
        error("workspace_path_not_regular", resolved)

      {:error, reason} ->
        file_error("workspace_path_unavailable", resolved, reason)
    end
  end

  defp write_payload(_root, _resolved, content, _mode), do: {:ok, content}

  defp replace_from_temp(root, resolved, parent, payload, mode) do
    temp = Path.join(parent, ".hydra-write-#{random_token()}")

    try do
      with {:ok, ^temp} <- resolve(root, temp, kind: :write),
           :ok <- write_exclusive_temp(temp, payload),
           :ok <- preserve_mode(resolved, temp),
           {:ok, ^temp} <- resolve(root, temp, kind: :regular),
           :ok <- install_temp(temp, resolved, mode) do
        :ok
      end
    after
      File.rm(temp)
    end
  end

  defp write_exclusive_temp(path, payload) do
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- IO.binwrite(device, payload),
                :ok <- :file.sync(device) do
             :ok
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preserve_mode(target, temp) do
    mode =
      case File.lstat(target) do
        {:ok, %File.Stat{type: :regular, mode: existing_mode}} ->
          Bitwise.band(existing_mode, 0o777)

        _missing_or_invalid ->
          0o600
      end

    File.chmod(temp, mode)
  end

  defp install_temp(temp, target, :create_new) do
    case File.ln(temp, target) do
      :ok -> File.rm(temp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_temp(temp, target, _mode), do: File.rename(temp, target)

  defp ensure_same_file(before, after_stat, path) do
    if file_identity(before) == file_identity(after_stat),
      do: :ok,
      else: error("workspace_path_changed_during_operation", path)
  end

  defp file_identity(stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode}
  end

  defp walk_directory(boundary, directory, files) do
    with {:ok, entries} <- File.ls(directory) do
      Enum.reduce_while(Enum.sort(entries), {:ok, files}, fn entry, {:ok, acc} ->
        path = Path.join(directory, entry)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            {:cont, {:ok, [path | acc]}}

          {:ok, %File.Stat{type: :directory}} ->
            case walk_directory(boundary, path, acc) do
              {:ok, nested} -> {:cont, {:ok, nested}}
              {:error, _reason} = error -> {:halt, error}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, error("workspace_path_symlink", Path.relative_to(path, boundary))}

          {:ok, _stat} ->
            {:halt, error("workspace_path_unsupported_type", Path.relative_to(path, boundary))}

          {:error, reason} ->
            {:halt, file_error("workspace_path_unavailable", path, reason)}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, Enum.reverse(result)}
        error -> error
      end
    else
      {:error, reason} -> file_error("workspace_directory_list_failed", directory, reason)
    end
  end

  defp random_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp error(reason, path), do: {:error, %{"reason" => reason, "path" => path}}

  defp file_error(reason, path, detail),
    do: {:error, %{"reason" => reason, "path" => path, "detail" => to_string(detail)}}
end
