defmodule HydraAgent.Repo.Migrations.RequireActiveScriptPreview do
  use Ecto.Migration

  def up do
    execute(active_script_function(true))
  end

  def down do
    execute(active_script_function(false))
  end

  defp active_script_function(require_preview?) do
    preview_declaration = if require_preview?, do: "preview_status text;", else: ""

    preview_query =
      if require_preview? do
        """
        SELECT status INTO preview_status
        FROM simulation_script_previews
        WHERE simulation_script_id = NEW.active_script_id;

        IF preview_status IS NULL
           OR (script_status = 'ready' AND preview_status IS DISTINCT FROM 'passed')
           OR (script_status = 'blocked' AND preview_status IS DISTINCT FROM 'failed')
           OR script_status = 'invalid' THEN
          RAISE EXCEPTION 'active script requires matching preview evidence';
        END IF;
        """
      else
        ""
      end

    """
    CREATE OR REPLACE FUNCTION validate_simulation_active_script()
    RETURNS trigger AS $$
    DECLARE
      script_simulation_id bigint;
      script_workspace_id bigint;
      script_version_id bigint;
      script_context_id bigint;
      script_population_id bigint;
      script_status text;
      #{preview_declaration}
    BEGIN
      IF NEW.active_script_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT simulation_id, workspace_id, simulation_version_id, context_pack_id,
             population_model_id, status
      INTO script_simulation_id, script_workspace_id, script_version_id,
           script_context_id, script_population_id, script_status
      FROM simulation_scripts
      WHERE id = NEW.active_script_id;

      IF script_simulation_id IS NULL
         OR script_simulation_id IS DISTINCT FROM NEW.id
         OR script_workspace_id IS DISTINCT FROM NEW.workspace_id
         OR script_version_id IS DISTINCT FROM NEW.active_version_id
         OR script_context_id IS DISTINCT FROM NEW.active_context_pack_id
         OR script_population_id IS DISTINCT FROM NEW.active_population_model_id THEN
        RAISE EXCEPTION 'active script does not belong to the active population model';
      END IF;

      #{preview_query}

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
