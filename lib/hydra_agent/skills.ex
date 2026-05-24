defmodule HydraAgent.Skills do
  @moduledoc """
  Durable skill library.

  Skills are proposed, tested, activated, deprecated, and audited as workspace
  data instead of being hidden prompt text.
  """

  import Ecto.Query

  alias HydraAgent.Repo
  alias HydraAgent.Skills.Skill

  def list_skills(workspace_id, opts \\ []) do
    Skill
    |> where([skill], skill.workspace_id == ^workspace_id)
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([skill], asc: skill.name)
    |> Repo.all()
  end

  def get_skill!(id), do: Repo.get!(Skill, id)

  def create_skill(attrs) do
    %Skill{} |> Skill.changeset(stringify_keys(attrs)) |> Repo.insert()
  end

  def transition_skill(%Skill{} = skill, status, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", status)
      |> put_status_timestamp(status)

    skill |> Skill.changeset(attrs) |> Repo.update()
  end

  def activate_skill(%Skill{} = skill, attrs \\ %{}), do: transition_skill(skill, "active", attrs)
  def test_skill(%Skill{} = skill, attrs \\ %{}), do: transition_skill(skill, "testing", attrs)

  def deprecate_skill(%Skill{} = skill, attrs \\ %{}),
    do: transition_skill(skill, "deprecated", attrs)

  def archive_skill(%Skill{} = skill, attrs \\ %{}),
    do: transition_skill(skill, "archived", attrs)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [skill], skill.status == ^status)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp put_status_timestamp(attrs, "active"), do: Map.put_new(attrs, "activated_at", now())
  defp put_status_timestamp(attrs, "deprecated"), do: Map.put_new(attrs, "deprecated_at", now())
  defp put_status_timestamp(attrs, _status), do: attrs

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
