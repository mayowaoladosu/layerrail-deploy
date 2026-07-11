class CreateProjectsAndEnvironments < ActiveRecord::Migration[8.1]
  LIFECYCLE_STATES = %w[
    active
    deletion_requested
    draining
    deleting_resources
    tombstoned
    permanently_deleted
  ].freeze

  ENVIRONMENT_KINDS = %w[production staging custom].freeze

  def change
    create_table :projects, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :name, null: false, limit: 120
      table.string :slug, null: false, limit: 64
      table.string :lifecycle_state, null: false, limit: 32, default: "active"
      table.timestamps
    end

    add_index :projects, "organization_id, LOWER(name)",
      unique: true,
      name: "index_projects_on_organization_and_lower_name"
    add_index :projects, [ :organization_id, :slug ], unique: true
    add_index :projects, [ :organization_id, :lifecycle_state ]
    add_check_constraint :projects, "BTRIM(name) <> ''", name: "projects_name_present"
    add_check_constraint :projects,
      "slug = LOWER(BTRIM(slug)) AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'",
      name: "projects_slug_normalized"
    add_check_constraint :projects, allowed_values("lifecycle_state", LIFECYCLE_STATES),
      name: "projects_lifecycle_state_allowed"

    create_table :environments, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :project, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :name, null: false, limit: 120
      table.string :slug, null: false, limit: 64
      table.string :kind, null: false, limit: 16
      table.string :branch, limit: 255
      table.string :lifecycle_state, null: false, limit: 32, default: "active"
      table.timestamps
    end

    add_index :environments, [ :project_id, :slug ], unique: true
    add_index :environments, [ :project_id, :branch ], unique: true, where: "branch IS NOT NULL"
    add_index :environments, :project_id,
      unique: true,
      where: "kind = 'production'",
      name: "index_environments_on_one_production_per_project"
    add_index :environments, :project_id,
      unique: true,
      where: "kind = 'staging'",
      name: "index_environments_on_one_staging_per_project"
    add_index :environments, [ :project_id, :lifecycle_state ]
    add_check_constraint :environments, "BTRIM(name) <> ''", name: "environments_name_present"
    add_check_constraint :environments,
      "slug = LOWER(BTRIM(slug)) AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'",
      name: "environments_slug_normalized"
    add_check_constraint :environments,
      "branch IS NULL OR (branch = BTRIM(branch) AND branch <> '')",
      name: "environments_branch_normalized"
    add_check_constraint :environments, allowed_values("kind", ENVIRONMENT_KINDS),
      name: "environments_kind_allowed"
    add_check_constraint :environments, allowed_values("lifecycle_state", LIFECYCLE_STATES),
      name: "environments_lifecycle_state_allowed"
  end

  private

  def allowed_values(column, values)
    values.map { |value| "#{column} = #{connection.quote(value)}" }.join(" OR ")
  end
end
