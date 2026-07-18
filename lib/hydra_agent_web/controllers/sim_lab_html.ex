defmodule HydraAgentWeb.SimLabHTML do
  use HydraAgentWeb, :html

  def sentence_fragment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim_trailing("!")
    |> String.trim_trailing("?")
    |> then(fn
      "" ->
        "the trigger occurs"

      text ->
        {first, rest} = String.split_at(text, 1)
        String.downcase(first) <> rest
    end)
  end

  def sentence_fragment(_value), do: "the trigger occurs"

  def behavior_label("ignore"), do: "wait"
  def behavior_label(action), do: action

  def assumption_text(%{} = assumption),
    do: assumption["statement"] || assumption[:statement] || "Recorded assumption"

  def assumption_text(assumption) when is_binary(assumption), do: assumption
  def assumption_text(_assumption), do: "Recorded assumption"

  def pluralize(1, singular, _plural), do: singular
  def pluralize(_count, _singular, plural), do: plural

  def evidence_impact_text(evidence) do
    metadata = evidence.metadata || %{}
    review_status = metadata["review_status"] || "unreviewed"
    impact = evidence.simulation_impact || "Review before using this evidence in the model."

    case {review_status, impact} do
      {"reviewed", "Requires review before it changes generated behavior."} ->
        "Reviewed for model provenance. Its influence remains directional."

      {"dismissed", _impact} ->
        "Dismissed. It is excluded from generated behavior."

      _other ->
        impact
    end
  end

  attr :workspace_id, :any, required: true
  attr :study_id, :any, required: true
  attr :evidence, :any, required: true
  attr :compact, :boolean, default: false

  def evidence_review_controls(assigns) do
    review_status = (assigns.evidence.metadata || %{})["review_status"] || "unreviewed"
    assigns = assign(assigns, :review_status, review_status)

    ~H"""
    <div class={["evidence-review-controls", @compact && "compact"]}>
      <span class={"review-state is-#{@review_status}"}>
        {String.replace(@review_status, "_", " ")}
      </span>
      <form
        :if={@review_status != "reviewed"}
        action={"/lab/workspaces/#{@workspace_id}/studies/#{@study_id}/evidence/#{@evidence.id}/review"}
        method="post"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="decision" value="reviewed" />
        <button type="submit">Use in model</button>
      </form>
      <form
        :if={@review_status != "dismissed"}
        action={"/lab/workspaces/#{@workspace_id}/studies/#{@study_id}/evidence/#{@evidence.id}/review"}
        method="post"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="decision" value="dismissed" />
        <button class="dismiss-evidence" type="submit">Dismiss</button>
      </form>
    </div>
    """
  end

  embed_templates "sim_lab_html/*"
end
