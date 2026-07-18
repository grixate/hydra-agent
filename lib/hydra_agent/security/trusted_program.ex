defmodule HydraAgent.Security.TrustedProgram do
  @moduledoc """
  Resolves an allowlisted bare program name once and pins execution to that
  absolute executable. This prevents path aliases and workspace-controlled
  `PATH` entries from bypassing an argv allowlist between authorization and
  execution.
  """

  alias HydraAgent.Security.WorkspacePath

  @program_name ~r/^[A-Za-z0-9][A-Za-z0-9._+-]*$/

  def resolve(program, workspace_root, opts \\ [])

  def resolve(program, workspace_root, opts) when is_binary(program) do
    allowed = Keyword.get(opts, :allowed)

    with :ok <- validate_name(program),
         :ok <- validate_allowlist(program, allowed),
         executable when is_binary(executable) <- System.find_executable(program),
         {:ok, canonical} <- canonical_executable(executable),
         :ok <- reject_workspace_program(canonical, workspace_root),
         :ok <- validate_executable(canonical) do
      {:ok, canonical}
    else
      nil -> {:error, %{"reason" => "command_program_not_found", "program" => program}}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_program, _workspace_root, _opts),
    do: {:error, %{"reason" => "command_program_must_be_string"}}

  defp validate_name(program) do
    if Regex.match?(@program_name, program) do
      :ok
    else
      {:error, %{"reason" => "unsafe_command_program", "program" => program}}
    end
  end

  defp validate_allowlist(_program, nil), do: :ok

  defp validate_allowlist(program, allowed) when is_list(allowed) do
    if program in allowed,
      do: :ok,
      else: {:error, %{"reason" => "command_program_not_allowed", "program" => program}}
  end

  defp validate_allowlist(program, _allowed),
    do: {:error, %{"reason" => "command_program_not_allowed", "program" => program}}

  defp canonical_executable(path) do
    canonical_executable(path, 0)
  end

  defp canonical_executable(_path, depth) when depth > 16,
    do: {:error, %{"reason" => "command_program_symlink_loop"}}

  defp canonical_executable(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, Path.expand(path)}

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, resolved} ->
            resolved
            |> Path.expand(Path.dirname(path))
            |> canonical_executable(depth + 1)

          {:error, reason} ->
            {:error, %{"reason" => "command_program_unresolvable", "detail" => to_string(reason)}}
        end

      {:ok, _stat} ->
        {:error, %{"reason" => "command_program_not_regular", "program" => path}}

      {:error, reason} ->
        {:error, %{"reason" => "command_program_unavailable", "detail" => to_string(reason)}}
    end
  end

  defp reject_workspace_program(path, workspace_root) when is_binary(workspace_root) do
    if WorkspacePath.lexically_inside?(path, workspace_root) do
      {:error, %{"reason" => "workspace_command_program_rejected", "program" => path}}
    else
      :ok
    end
  end

  defp reject_workspace_program(_path, _workspace_root), do: :ok

  defp validate_executable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0,
          do: :ok,
          else: {:error, %{"reason" => "command_program_not_executable", "program" => path}}

      {:ok, _stat} ->
        {:error, %{"reason" => "command_program_not_regular", "program" => path}}

      {:error, reason} ->
        {:error, %{"reason" => "command_program_unavailable", "detail" => to_string(reason)}}
    end
  end
end
