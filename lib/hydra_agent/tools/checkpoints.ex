defmodule HydraAgent.Tools.Checkpoints do
  @moduledoc """
  Lightweight filesystem checkpoints for side-effecting tools.

  Checkpoints live inside the workspace under `.hydra/checkpoints` and copy the
  previous file contents before a write or shell command can mutate them.
  """

  import Ecto.Query

  alias HydraAgent.{Repo, Runtime}
  alias HydraAgent.Security.WorkspacePath
  alias HydraAgent.Tools.CheckpointRecord

  def file_checkpoint(path, context, opts \\ []) when is_binary(path) do
    context = stringify_keys(context || %{})
    root = workspace_root(context)
    enabled? = Keyword.get(opts, :enabled, true)

    checkpoint =
      cond do
        not enabled? ->
          %{"enabled" => false, "path" => path}

        true ->
          create_file_checkpoint(path, root)
      end

    maybe_record_checkpoint(checkpoint, context, opts)
  end

  def path_checkpoints(paths, context) when is_list(paths) do
    Enum.map(paths, fn path ->
      path
      |> to_string()
      |> expand_path(context)
      |> file_checkpoint(context)
    end)
  end

  def path_checkpoints(_paths, _context), do: []

  def list_records(workspace_id, opts \\ []) do
    CheckpointRecord
    |> where([checkpoint], checkpoint.workspace_id == ^workspace_id)
    |> maybe_filter_run(opt(opts, :run_id))
    |> order_by([checkpoint], desc: checkpoint.inserted_at)
    |> limit(^opt(opts, :limit, 50))
    |> Repo.all()
  end

  def get_record!(id), do: Repo.get!(CheckpointRecord, id)

  def get_record_for_workspace!(workspace_id, id) do
    CheckpointRecord
    |> where(
      [checkpoint],
      checkpoint.workspace_id == ^normalize_id(workspace_id) and
        checkpoint.id == ^normalize_id(id)
    )
    |> Repo.one!()
  end

  def restore_record_for_workspace(workspace_id, id, context \\ %{}) do
    checkpoint = get_record_for_workspace!(workspace_id, id)

    context
    |> trusted_workspace_context(workspace_id)
    |> then(&restore_checkpoint(checkpoint, &1))
  end

  def restore_record(id, context \\ %{}) do
    checkpoint = get_record!(id)
    restore_checkpoint(checkpoint, context)
  end

  def diff_record_for_workspace(workspace_id, id, context \\ %{}) do
    checkpoint = get_record_for_workspace!(workspace_id, id)

    context
    |> trusted_workspace_context(workspace_id)
    |> then(&diff_checkpoint(checkpoint, &1))
  end

  def diff_record(id, context \\ %{}) do
    checkpoint = get_record!(id)
    diff_checkpoint(checkpoint, context)
  end

  defp restore_checkpoint(checkpoint, context) do
    context = stringify_keys(context || %{})
    root = workspace_root(context)

    with {:ok, target_path} <- validate_restore_target(checkpoint.path, root),
         {:ok, previous} <- validate_checkpoint_file(checkpoint, root),
         :ok <- restore_contents(checkpoint, root, target_path, previous) do
      restored_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      checkpoint
      |> CheckpointRecord.changeset(%{"restored_at" => restored_at})
      |> Repo.update()
      |> case do
        {:ok, restored} ->
          {:ok,
           %{
             "id" => restored.id,
             "path" => restored.path,
             "checkpoint_path" => restored.checkpoint_path,
             "restored_at" => restored.restored_at,
             "sha256" => restored_sha(root, restored.path),
             "existed" => restored.existed
           }}

        error ->
          error
      end
    end
  end

  defp diff_checkpoint(checkpoint, context) do
    context = stringify_keys(context || %{})
    root = workspace_root(context)

    with {:ok, target_path} <- validate_restore_target(checkpoint.path, root),
         {:ok, previous} <- validate_checkpoint_file(checkpoint, root),
         {:ok, current} <- current_contents(root, target_path) do
      {:ok,
       %{
         "id" => checkpoint.id,
         "path" => checkpoint.path,
         "changed" => current != previous,
         "previous_sha256" => checkpoint.sha256,
         "current_sha256" => if(current == "", do: nil, else: sha256(current)),
         "diff" => simple_diff(previous, current)
       }}
    end
  end

  def expand_path(path, context) do
    root = workspace_root(context)
    Path.expand(path, root)
  end

  def workspace_root(context) do
    context = stringify_keys(context || %{})
    Path.expand(context["workspace_root"] || File.cwd!())
  end

  def inside_root?(path, root) do
    WorkspacePath.lexically_inside?(path, root)
  end

  defp checkpoint_path(root, rel_path) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_unix(:microsecond)
      |> Integer.to_string()

    hash = :crypto.hash(:sha256, rel_path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    Path.join([root, ".hydra", "checkpoints", "#{stamp}-#{hash}", rel_path])
  end

  defp maybe_record_checkpoint(
         %{"enabled" => true} = checkpoint,
         %{"workspace_id" => workspace_id} = context,
         opts
       )
       when not is_nil(workspace_id) and workspace_id != "" do
    attrs =
      checkpoint
      |> Map.merge(%{
        "workspace_id" => context["workspace_id"],
        "run_id" => context["run_id"],
        "run_step_id" => context["run_step_id"],
        "tool_name" => Keyword.get(opts, :tool_name) || context["tool_name"],
        "metadata" => %{
          "workspace_root" => workspace_root(context),
          "reason" => Keyword.get(opts, :reason, "tool_side_effect")
        }
      })

    case %CheckpointRecord{} |> CheckpointRecord.changeset(attrs) |> Repo.insert() do
      {:ok, record} -> Map.put(checkpoint, "record_id", record.id)
      {:error, changeset} -> Map.put(checkpoint, "record_error", inspect(changeset.errors))
    end
  end

  defp maybe_record_checkpoint(checkpoint, _context, _opts), do: checkpoint

  defp validate_restore_target(path, root) do
    case WorkspacePath.resolve(root, path, kind: :write) do
      {:ok, target} ->
        {:ok, target}

      {:error, %{"reason" => "path_outside_workspace_root"}} ->
        {:error, %{"reason" => "restore_path_outside_workspace"}}

      error ->
        error
    end
  end

  defp validate_checkpoint_file(%CheckpointRecord{existed: false}, _root), do: {:ok, ""}

  defp validate_checkpoint_file(%CheckpointRecord{checkpoint_path: path, sha256: expected}, root)
       when is_binary(path) and is_binary(expected) do
    checkpoint_root = Path.join([root, ".hydra", "checkpoints"])

    cond do
      not WorkspacePath.lexically_inside?(path, checkpoint_root) ->
        {:error, %{"reason" => "checkpoint_path_outside_store", "path" => path}}

      true ->
        case WorkspacePath.read_regular(root, path) do
          {:ok, content} ->
            if sha256(content) == expected do
              {:ok, content}
            else
              {:error, %{"reason" => "checkpoint_sha256_mismatch", "path" => path}}
            end

          {:error, %{"reason" => "workspace_path_missing"}} ->
            {:error, %{"reason" => "checkpoint_file_missing", "path" => path}}

          error ->
            error
        end
    end
  end

  defp validate_checkpoint_file(_checkpoint, _root),
    do: {:error, %{"reason" => "checkpoint_file_missing"}}

  defp simple_diff(previous, current) do
    previous_lines = String.split(previous, "\n")
    current_lines = String.split(current, "\n")

    if previous_lines == current_lines do
      ""
    else
      removed = previous_lines -- current_lines
      added = current_lines -- previous_lines

      Enum.map_join(removed, "\n", &"- #{&1}") <>
        if(removed != [] and added != [], do: "\n", else: "") <>
        Enum.map_join(added, "\n", &"+ #{&1}")
    end
  end

  defp maybe_filter_run(query, nil), do: query

  defp maybe_filter_run(query, run_id),
    do: where(query, [checkpoint], checkpoint.run_id == ^run_id)

  defp trusted_workspace_context(context, workspace_id) do
    (context || %{})
    |> stringify_keys()
    |> Map.put("workspace_root", Runtime.trusted_workspace_root(workspace_id))
  end

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
  defp opt(opts, key, default), do: opt(opts, key) || default

  defp create_file_checkpoint(path, root) do
    with {:ok, resolved} <- WorkspacePath.resolve(root, path, kind: :write) do
      relative_path = Path.relative_to(resolved, root)

      case File.lstat(resolved) do
        {:error, :enoent} ->
          %{"enabled" => true, "path" => resolved, "existed" => false}

        {:ok, %File.Stat{type: :regular}} ->
          checkpoint_path = checkpoint_path(root, relative_path)

          with {:ok, content} <- WorkspacePath.read_regular(root, resolved),
               :ok <- WorkspacePath.atomic_write(root, checkpoint_path, content, :create_new) do
            %{
              "enabled" => true,
              "path" => resolved,
              "relative_path" => relative_path,
              "checkpoint_path" => checkpoint_path,
              "existed" => true,
              "sha256" => sha256(content)
            }
          else
            {:error, reason} -> checkpoint_error(resolved, reason)
          end

        {:ok, _stat} ->
          checkpoint_error(resolved, %{"reason" => "workspace_path_not_regular"})

        {:error, reason} ->
          checkpoint_error(resolved, %{
            "reason" => "workspace_path_unavailable",
            "detail" => reason
          })
      end
    else
      {:error, reason} -> checkpoint_error(path, reason)
    end
  end

  defp checkpoint_error(path, reason) do
    %{
      "enabled" => false,
      "path" => path,
      "reason" => reason["reason"] || "checkpoint_failed",
      "error" => reason
    }
  end

  defp current_contents(root, path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, ""}

      {:ok, %File.Stat{type: :regular}} ->
        WorkspacePath.read_regular(root, path)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, %{"reason" => "workspace_path_symlink", "path" => path}}

      {:ok, _stat} ->
        {:error, %{"reason" => "workspace_path_not_regular", "path" => path}}

      {:error, reason} ->
        {:error, %{"reason" => "workspace_path_unavailable", "detail" => reason}}
    end
  end

  defp restored_sha(root, path) do
    case WorkspacePath.read_regular(root, path) do
      {:ok, content} -> sha256(content)
      _missing_or_error -> nil
    end
  end

  defp restore_contents(%CheckpointRecord{existed: true}, root, target_path, previous),
    do: WorkspacePath.atomic_write(root, target_path, previous, :overwrite)

  defp restore_contents(%CheckpointRecord{existed: false}, root, target_path, _previous),
    do: WorkspacePath.remove(root, target_path)

  defp sha256(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
