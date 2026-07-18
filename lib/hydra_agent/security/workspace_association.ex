defmodule HydraAgent.Security.WorkspaceAssociation do
  @moduledoc """
  Changeset validation for associations that must stay inside a workspace.

  Ordinary foreign keys prove only that a referenced row exists. This helper
  also proves that the referenced row belongs to the record's workspace, so a
  nested API request cannot create a cross-workspace relationship by supplying
  another tenant's numeric id.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias HydraAgent.Repo

  @spec validate(Ecto.Changeset.t(), atom(), module(), keyword()) :: Ecto.Changeset.t()
  def validate(changeset, association_field, schema, opts \\ []) do
    workspace_field = Keyword.get(opts, :workspace_field, :workspace_id)
    record_workspace_field = Keyword.get(opts, :record_workspace_field, :workspace_id)

    if validation_needed?(changeset, workspace_field, association_field) do
      workspace_id =
        if Keyword.has_key?(opts, :workspace_id),
          do: Keyword.fetch!(opts, :workspace_id),
          else: get_field(changeset, workspace_field)

      association_id = get_field(changeset, association_field)

      validate_reference(
        changeset,
        association_field,
        schema,
        record_workspace_field,
        workspace_id,
        association_id,
        opts
      )
    else
      changeset
    end
  end

  defp validation_needed?(
         %Ecto.Changeset{data: %{id: nil}},
         _workspace_field,
         _association_field
       ),
       do: true

  defp validation_needed?(changeset, workspace_field, association_field) do
    Map.has_key?(changeset.changes, workspace_field) or
      Map.has_key?(changeset.changes, association_field)
  end

  defp validate_reference(
         changeset,
         _field,
         _schema,
         _record_workspace_field,
         _workspace,
         nil,
         _opts
       ),
       do: changeset

  defp validate_reference(
         changeset,
         field,
         schema,
         record_workspace_field,
         workspace_id,
         association_id,
         opts
       ) do
    allow_global? = Keyword.get(opts, :allow_global, false)

    matching? =
      schema
      |> where([record], field(record, :id) == ^association_id)
      |> matching_workspace(record_workspace_field, workspace_id, allow_global?)
      |> Repo.exists?()

    if matching? do
      changeset
    else
      add_error(changeset, field, "must belong to the same workspace")
    end
  end

  defp matching_workspace(query, workspace_field, nil, true),
    do: where(query, [record], is_nil(field(record, ^workspace_field)))

  defp matching_workspace(query, _workspace_field, nil, false),
    do: where(query, [record], false)

  defp matching_workspace(query, workspace_field, workspace_id, true) do
    where(
      query,
      [record],
      field(record, ^workspace_field) == ^workspace_id or
        is_nil(field(record, ^workspace_field))
    )
  end

  defp matching_workspace(query, workspace_field, workspace_id, false),
    do: where(query, [record], field(record, ^workspace_field) == ^workspace_id)
end
