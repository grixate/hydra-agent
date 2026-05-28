defmodule HydraAgent.Tools.Checkpoints do
  @moduledoc """
  Lightweight filesystem checkpoints for side-effecting tools.

  Checkpoints live inside the workspace under `.hydra/checkpoints` and copy the
  previous file contents before a write or shell command can mutate them.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Tools.CheckpointRecord

  def file_checkpoint(path, context, opts \\ []) when is_binary(path) do
    context = stringify_keys(context || %{})
    root = workspace_root(context)
    rel_path = Path.relative_to(path, root)
    enabled? = Keyword.get(opts, :enabled, true)

    checkpoint =
      cond do
        not enabled? ->
          %{"enabled" => false, "path" => path}

        not inside_root?(path, root) ->
          %{"enabled" => false, "path" => path, "reason" => "path_outside_workspace_root"}

        not File.exists?(path) ->
          %{"enabled" => true, "path" => path, "existed" => false}

        true ->
          checkpoint_path = checkpoint_path(root, rel_path)
          File.mkdir_p!(Path.dirname(checkpoint_path))
          File.cp!(path, checkpoint_path)

          %{
            "enabled" => true,
            "path" => path,
            "relative_path" => rel_path,
            "checkpoint_path" => checkpoint_path,
            "existed" => true,
            "sha256" => sha256_file(checkpoint_path)
          }
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
    restore_checkpoint(checkpoint, context)
  end

  def restore_record(id, context \\ %{}) do
    checkpoint = get_record!(id)
    restore_checkpoint(checkpoint, context)
  end

  def diff_record_for_workspace(workspace_id, id, context \\ %{}) do
    checkpoint = get_record_for_workspace!(workspace_id, id)
    diff_checkpoint(checkpoint, context)
  end

  def diff_record(id, context \\ %{}) do
    checkpoint = get_record!(id)
    diff_checkpoint(checkpoint, context)
  end

  defp restore_checkpoint(checkpoint, context) do
    context = stringify_keys(context || %{})
    root = workspace_root(context)
    target_path = checkpoint.path

    with :ok <- validate_restore_target(target_path, root),
         :ok <- validate_checkpoint_file(checkpoint) do
      if checkpoint.existed do
        File.mkdir_p!(Path.dirname(target_path))
        File.cp!(checkpoint.checkpoint_path, target_path)
      else
        File.rm(target_path)
      end

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
             "sha256" => if(File.exists?(restored.path), do: sha256_file(restored.path)),
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

    with :ok <- validate_restore_target(checkpoint.path, root),
         :ok <- validate_checkpoint_file(checkpoint) do
      current = if File.exists?(checkpoint.path), do: File.read!(checkpoint.path), else: ""
      previous = File.read!(checkpoint.checkpoint_path)

      {:ok,
       %{
         "id" => checkpoint.id,
         "path" => checkpoint.path,
         "changed" => current != previous,
         "previous_sha256" => checkpoint.sha256,
         "current_sha256" => if(File.exists?(checkpoint.path), do: sha256_file(checkpoint.path)),
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
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
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
    if inside_root?(path, root),
      do: :ok,
      else: {:error, %{"reason" => "restore_path_outside_workspace"}}
  end

  defp validate_checkpoint_file(%CheckpointRecord{existed: false}), do: :ok

  defp validate_checkpoint_file(%CheckpointRecord{checkpoint_path: path}) when is_binary(path) do
    if File.exists?(path),
      do: :ok,
      else: {:error, %{"reason" => "checkpoint_file_missing", "path" => path}}
  end

  defp validate_checkpoint_file(_checkpoint),
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

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
  defp opt(opts, key, default), do: opt(opts, key) || default

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
