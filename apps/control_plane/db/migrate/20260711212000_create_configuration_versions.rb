class CreateConfigurationVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :configuration_versions, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :project_id, null: false
      table.uuid :environment_id, null: false
      table.uuid :service_id
      table.references :created_by, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :restrict }
      table.string :scope_key, null: false, limit: 255
      table.integer :version, null: false
      table.jsonb :key_summary, null: false
      table.text :payload_json, null: false
      table.string :payload_digest, null: false, limit: 64
      table.timestamps
    end

    add_index :configuration_versions,
      [ :environment_id, :scope_key, :version ],
      unique: true,
      name: "index_configuration_versions_on_environment_scope_version"
    add_index :configuration_versions,
      [ :organization_id, :project_id, :environment_id ],
      name: "index_configuration_versions_on_tenant_scope"
    add_index :configuration_versions, [ :service_id, :environment_id ]
    add_index :environments, [ :id, :project_id ], unique: true
    add_foreign_key :configuration_versions,
      :projects,
      column: [ :project_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
    add_foreign_key :configuration_versions,
      :environments,
      column: [ :environment_id, :project_id ],
      primary_key: [ :id, :project_id ],
      on_delete: :restrict
    add_foreign_key :configuration_versions,
      :services,
      column: [ :service_id, :project_id ],
      primary_key: [ :id, :project_id ],
      on_delete: :restrict
    add_check_constraint :configuration_versions,
      "version > 0",
      name: "configuration_versions_version_positive"
    add_check_constraint :configuration_versions,
      "payload_digest ~ '^[0-9a-f]{64}$'",
      name: "configuration_versions_digest_format"
    add_check_constraint :configuration_versions,
      "jsonb_typeof(key_summary) = 'array'",
      name: "configuration_versions_key_summary_array"
    add_check_constraint :configuration_versions,
      "(service_id IS NULL AND scope_key = 'project') OR (service_id IS NOT NULL AND scope_key = 'service:' || service_id::text)",
      name: "configuration_versions_scope_matches_service"
  end
end
