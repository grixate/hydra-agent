defmodule HydraAgentWeb.SetupLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Runtime, Setup}

  @impl true
  def mount(_params, _session, socket) do
    workspaces = Runtime.list_workspaces()

    {:ok,
     socket
     |> assign(:page_title, "Setup")
     |> assign(:workspaces, workspaces)
     |> assign(:form, Setup.default_attrs())
     |> assign(:errors, [])
     |> assign(:provider_options, Setup.provider_options())}
  end

  @impl true
  def handle_event("validate", %{"setup" => attrs}, socket) do
    {:noreply,
     socket
     |> assign(:form, normalize_form(attrs))
     |> assign(:errors, [])}
  end

  def handle_event("bootstrap", %{"setup" => attrs}, socket) do
    attrs = normalize_form(attrs)

    case Setup.bootstrap(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Hydra workspace is ready")
         |> push_navigate(to: ~p"/control?workspace_id=#{result.workspace.id}")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, attrs)
         |> assign(:errors, format_error(error))}
    end
  end

  defp normalize_form(attrs) do
    defaults = Setup.default_attrs()
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    defaults
    |> Map.merge(attrs)
    |> Map.update!("workspace_name", &String.trim(to_string(&1)))
    |> Map.update!("workspace_slug", &String.trim(to_string(&1)))
    |> Map.update!("provider_kind", &String.trim(to_string(&1)))
    |> Map.update!("provider_model", &String.trim(to_string(&1)))
    |> Map.update!("provider_base_url", &String.trim(to_string(&1)))
    |> Map.update!("provider_api_key_env", &String.trim(to_string(&1)))
    |> normalize_checkbox("seed_skills")
    |> normalize_checkbox("install_starter_agents")
  end

  defp normalize_checkbox(attrs, key) do
    Map.put(
      attrs,
      key,
      if(Map.get(attrs, key) in ["true", "on", "1", true], do: "true", else: "false")
    )
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field} #{&1}")
    end)
  end

  defp format_error(errors) when is_list(errors), do: Enum.map(errors, &inspect/1)
  defp format_error(error), do: [inspect(error)]

  defp provider_hint("mock"), do: "Works immediately. Good for smoke tests and learning the UI."
  defp provider_hint("ollama"), do: "Uses your local Ollama endpoint. API key is optional."

  defp provider_hint("none"),
    do: "Hydra will boot, but starter agents cannot answer until a provider is added."

  defp provider_hint(_kind),
    do:
      "Set this env var on the server before using the provider. Hydra stores only the env var name."

  defp show_provider_details?(%{"provider_kind" => "none"}), do: false
  defp show_provider_details?(_form), do: true

  defp model_value(%{"provider_model" => ""} = form),
    do: Setup.model_placeholder(form["provider_kind"])

  defp model_value(form), do: form["provider_model"]

  @impl true
  def render(assigns) do
    ~H"""
    <section id="setup-page" class="mx-auto max-w-5xl py-8">
      <div class="grid gap-8 lg:grid-cols-[0.75fr_1.25fr]">
        <aside class="space-y-5">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-[var(--accent)]">
              First run
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-normal text-zinc-950">
              Set up Hydra
            </h1>
            <p class="mt-3 text-sm leading-6 text-zinc-600">
              Create one workspace, add a route-compatible provider, and install the starter runtime pieces.
            </p>
          </div>

          <div class="rounded-[var(--radius-4)] border border-zinc-200 bg-[var(--bg-card-subtle)] p-4 text-sm leading-6 text-zinc-600">
            <p class="font-medium text-zinc-950">What this creates</p>
            <ul class="mt-2 space-y-1">
              <li>Workspace and graph types</li>
              <li>Provider routes named strong and fast</li>
              <li>Starter agents with explicit tool policies</li>
              <li>Standard reusable skills</li>
            </ul>
          </div>
        </aside>

        <%= if @workspaces == [] do %>
          <.form
            :let={f}
            as={:setup}
            for={@form}
            id="setup-form"
            phx-change="validate"
            phx-submit="bootstrap"
            class="hx-card space-y-6"
          >
            <div>
              <h2 class="text-lg font-semibold text-zinc-950">Workspace</h2>
              <p class="mt-1 text-sm text-zinc-600">
                This is the top-level boundary for agents, memory, policies, and runs.
              </p>
              <div class="mt-4 grid gap-4 sm:grid-cols-2">
                <label class="block text-sm">
                  <span class="font-medium text-zinc-700">Name</span>
                  <input
                    class="mt-1 w-full"
                    name={f[:workspace_name].name}
                    value={@form["workspace_name"]}
                  />
                </label>
                <label class="block text-sm">
                  <span class="font-medium text-zinc-700">Slug</span>
                  <input
                    class="mt-1 w-full"
                    name={f[:workspace_slug].name}
                    value={@form["workspace_slug"]}
                  />
                </label>
              </div>
            </div>

            <div class="border-t border-zinc-200 pt-6">
              <h2 class="text-lg font-semibold text-zinc-950">Provider</h2>
              <p class="mt-1 text-sm text-zinc-600">
                Mock is ready immediately. Real providers use env var references.
              </p>
              <div class="mt-4 grid gap-4 sm:grid-cols-2">
                <label class="block text-sm">
                  <span class="font-medium text-zinc-700">Provider</span>
                  <select class="mt-1 w-full" name={f[:provider_kind].name}>
                    <option
                      :for={{kind, label} <- @provider_options}
                      value={kind}
                      selected={@form["provider_kind"] == kind}
                    >
                      {label}
                    </option>
                  </select>
                </label>
                <label :if={show_provider_details?(@form)} class="block text-sm">
                  <span class="font-medium text-zinc-700">Model</span>
                  <input
                    class="mt-1 w-full"
                    name={f[:provider_model].name}
                    placeholder={Setup.model_placeholder(@form["provider_kind"])}
                    value={model_value(@form)}
                  />
                </label>
              </div>

              <div :if={show_provider_details?(@form)} class="mt-4 grid gap-4 sm:grid-cols-2">
                <label class="block text-sm">
                  <span class="font-medium text-zinc-700">Base URL</span>
                  <input
                    class="mt-1 w-full"
                    name={f[:provider_base_url].name}
                    placeholder="optional"
                    value={@form["provider_base_url"]}
                  />
                </label>
                <label class="block text-sm">
                  <span class="font-medium text-zinc-700">API key env</span>
                  <input
                    class="mt-1 w-full"
                    name={f[:provider_api_key_env].name}
                    placeholder="OPENAI_API_KEY"
                    value={@form["provider_api_key_env"]}
                  />
                </label>
              </div>

              <p class="mt-3 text-xs leading-5 text-zinc-500">
                {provider_hint(@form["provider_kind"])}
              </p>
            </div>

            <div class="border-t border-zinc-200 pt-6">
              <h2 class="text-lg font-semibold text-zinc-950">Starter Runtime</h2>
              <div class="mt-4 grid gap-3">
                <label class="flex items-start gap-3 rounded-[var(--radius-3)] border border-zinc-200 bg-[var(--bg-card-subtle)] p-3 text-sm">
                  <input type="hidden" name={f[:install_starter_agents].name} value="false" />
                  <input
                    class="mt-1"
                    type="checkbox"
                    name={f[:install_starter_agents].name}
                    value="true"
                    checked={@form["install_starter_agents"] == "true"}
                  />
                  <span>
                    <span class="block font-medium text-zinc-950">Install starter agents</span>
                    <span class="mt-0.5 block text-zinc-600">
                      Planner, researcher, builder, reviewer, memory, and Daily OS agents with least-privilege policies.
                    </span>
                  </span>
                </label>
                <label class="flex items-start gap-3 rounded-[var(--radius-3)] border border-zinc-200 bg-[var(--bg-card-subtle)] p-3 text-sm">
                  <input type="hidden" name={f[:seed_skills].name} value="false" />
                  <input
                    class="mt-1"
                    type="checkbox"
                    name={f[:seed_skills].name}
                    value="true"
                    checked={@form["seed_skills"] == "true"}
                  />
                  <span>
                    <span class="block font-medium text-zinc-950">Seed standard skills</span>
                    <span class="mt-0.5 block text-zinc-600">
                      Adds reusable skills for planning, review, memory, and handoffs.
                    </span>
                  </span>
                </label>
              </div>
            </div>

            <div
              :if={@errors != []}
              class="rounded-[var(--radius-3)] border border-red-200 bg-red-50 p-3 text-sm text-red-700"
            >
              <p class="font-medium">Setup needs attention</p>
              <ul class="mt-1 list-disc space-y-1 pl-5">
                <li :for={error <- @errors}>{error}</li>
              </ul>
            </div>

            <div class="flex items-center justify-end gap-3 border-t border-zinc-200 pt-6">
              <button type="submit" class="hx-button hx-button-primary">Create workspace</button>
            </div>
          </.form>
        <% else %>
          <div class="hx-card">
            <h2 class="text-lg font-semibold text-zinc-950">Hydra is already configured</h2>
            <p class="mt-2 text-sm text-zinc-600">
              This instance already has a workspace. Continue in the control plane.
            </p>
            <div class="mt-5">
              <.link
                navigate={~p"/control?workspace_id=#{List.first(@workspaces).id}"}
                class="hx-button hx-button-primary"
              >
                Open control
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end
end
