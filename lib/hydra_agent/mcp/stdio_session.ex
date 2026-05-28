defmodule HydraAgent.MCP.StdioSession do
  @moduledoc """
  Persistent JSON-RPC line session for stdio MCP servers.

  The session keeps the subprocess alive between calls and serializes requests
  through a GenServer, while preserving the same timeout and redaction contract
  used by one-shot stdio execution.
  """

  use GenServer

  alias HydraAgent.Redaction

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :server_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    server_id = Keyword.fetch!(opts, :server_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {HydraAgent.ProcessRegistry, {:mcp_stdio_session, server_id}}}
    )
  end

  def call(server_id, executable, args, cwd, env, request, timeout_ms, idle_timeout_ms) do
    opts = [
      server_id: server_id,
      executable: executable,
      args: args,
      cwd: cwd,
      env: env,
      idle_timeout_ms: idle_timeout_ms
    ]

    with {:ok, pid} <- ensure_started(server_id, opts) do
      GenServer.call(pid, {:request, request, timeout_ms}, timeout_ms + 1_000)
    end
  catch
    :exit, {:timeout, _call} ->
      {:error, %{"reason" => "mcp_stdio_timeout", "timeout_ms" => timeout_ms}}

    :exit, reason ->
      {:error, %{"reason" => "mcp_stdio_session_exit", "error" => inspect(reason)}}
  end

  def stop(server_id) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server_id}) do
      [{pid, _value}] ->
        :ok = GenServer.stop(pid, :normal, 5_000)
        wait_for_registry_empty(server_id)

      [] ->
        {:error, :not_found}
    end
  end

  def status(server_id) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server_id}) do
      [{pid, _value}] -> GenServer.call(pid, :status)
      [] -> %{"active" => false, "server_id" => server_id}
    end
  catch
    :exit, _reason -> %{"active" => false, "server_id" => server_id}
  end

  @impl true
  def init(opts) do
    port =
      Port.open({:spawn_executable, Keyword.fetch!(opts, :executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, Keyword.get(opts, :args, [])},
        {:cd, Keyword.fetch!(opts, :cwd)},
        {:env, Keyword.get(opts, :env, [])}
      ])

    now = now_iso8601()

    {:ok,
     %{
       port: port,
       server_id: Keyword.fetch!(opts, :server_id),
       idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 300_000),
       idle_timer_ref: nil,
       started_at: now,
       last_used_at: nil,
       request_count: 0
     }}
  rescue
    error ->
      {:stop, %{"reason" => "mcp_stdio_failed", "error" => Exception.message(error)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       "active" => true,
       "server_id" => state.server_id,
       "started_at" => state.started_at,
       "last_used_at" => state.last_used_at,
       "request_count" => state.request_count,
       "idle_timeout_ms" => state.idle_timeout_ms
     }, state}
  end

  def handle_call({:request, request, timeout_ms}, _from, %{port: port} = state) do
    state = cancel_idle_timer(state)
    Port.command(port, request)

    case collect_stdio(port, "", timeout_ms) do
      {:ok, line} ->
        state =
          state
          |> Map.put(:last_used_at, now_iso8601())
          |> Map.update!(:request_count, &(&1 + 1))
          |> schedule_idle_timer()

        {:reply, {:ok, line}, state}

      {:error, error} ->
        {:stop, :normal, {:error, error}, state}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    close_port(port)
  end

  defp ensure_started(server_id, opts) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server_id}) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(HydraAgent.MCP.SessionSupervisor, {__MODULE__, opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, error} ->
            {:error, %{"reason" => "mcp_stdio_session_start_failed", "error" => inspect(error)}}
        end
    end
  end

  defp wait_for_registry_empty(server_id, attempts \\ 20)

  defp wait_for_registry_empty(_server_id, 0), do: :ok

  defp wait_for_registry_empty(server_id, attempts) do
    case Registry.lookup(HydraAgent.ProcessRegistry, {:mcp_stdio_session, server_id}) do
      [] ->
        :ok

      _entries ->
        Process.sleep(5)
        wait_for_registry_empty(server_id, attempts - 1)
    end
  end

  defp schedule_idle_timer(%{idle_timeout_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    %{state | idle_timer_ref: Process.send_after(self(), :idle_timeout, timeout_ms)}
  end

  defp schedule_idle_timer(state), do: state

  defp cancel_idle_timer(%{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | idle_timer_ref: nil}
  end

  defp collect_stdio(port, buffer, timeout_ms) do
    case stdio_json_line(buffer) do
      {:ok, line} ->
        {:ok, line}

      :more ->
        receive do
          {^port, {:data, chunk}} ->
            collect_stdio(port, buffer <> chunk, timeout_ms)

          {^port, {:exit_status, status}} ->
            stdio_exit_result(buffer, status)
        after
          timeout_ms ->
            {:error, %{"reason" => "mcp_stdio_timeout", "timeout_ms" => timeout_ms}}
        end
    end
  end

  defp stdio_json_line(buffer) do
    buffer
    |> String.split("\n")
    |> Enum.find_value(:more, fn line ->
      line = String.trim(line)

      cond do
        line == "" -> false
        match?({:ok, %{}}, Jason.decode(line)) -> {:ok, line}
        true -> false
      end
    end)
  end

  defp stdio_exit_result(buffer, 0) do
    case stdio_json_line(buffer) do
      {:ok, line} -> {:ok, line}
      :more -> {:error, %{"reason" => "mcp_stdio_empty_response"}}
    end
  end

  defp stdio_exit_result(buffer, status) do
    {:error,
     %{
       "reason" => "mcp_stdio_exit",
       "exit_status" => status,
       "output" => Redaction.redact(String.trim(buffer))
     }}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _error -> :ok
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
