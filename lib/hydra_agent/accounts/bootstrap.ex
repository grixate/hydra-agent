defmodule HydraAgent.Accounts.Bootstrap do
  @moduledoc false

  use GenServer

  alias HydraAgent.Accounts

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    send(self(), :bootstrap)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    email = System.get_env("HYDRA_BOOTSTRAP_ADMIN_EMAIL")
    password = System.get_env("HYDRA_BOOTSTRAP_ADMIN_PASSWORD")

    if present?(email) and present?(password) and is_nil(Accounts.get_user_by_email(email)) do
      case Accounts.create_user(%{
             email: email,
             display_name: "Hydra administrator",
             password: password,
             global_role: "system_admin"
           }) do
        {:ok, _user} -> :ok
        {:error, reason} -> raise "could not create bootstrap administrator: #{inspect(reason)}"
      end
    end

    {:noreply, state}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
