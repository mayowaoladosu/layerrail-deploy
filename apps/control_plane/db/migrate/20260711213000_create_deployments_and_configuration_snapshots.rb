class CreateDeploymentsAndConfigurationSnapshots < ActiveRecord::Migration[8.1]
  STATUSES = %w[
    created queued preparing building scanning deploying verifying ready promoted
    superseded canceling canceled failed
  ].freeze
  CONCLUSIONS = %w[succeeded failed canceled].freeze
  TRIGGERS = %w[manual webhook redeploy rollback].freeze

  def change
    create_table :configuration_snapshots, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :project_id, null: false
      table.uuid :environment_id, null: false
      table.uuid :service_id, null: false
      table.uuid :project_configuration_version_id
      table.uuid :service_configuration_version_id
      table.references :created_by, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :restrict }
      table.jsonb :key_summary, null: false
      table.text :payload_json, null: false
      table.string :payload_digest, null: false, limit: 64
      table.timestamps
    end

    add_index :configuration_snapshots,
      [ :id, :organization_id, :project_id, :environment_id, :service_id ],
      unique: true,
      name: "index_configuration_snapshots_on_tenant_resource_identity"
    add_index :configuration_snapshots, [ :service_id, :environment_id, :created_at ]
    add_index :configuration_versions, [ :id, :project_id, :environment_id ], unique: true, name: "index_configuration_versions_on_resource_identity"
    add_foreign_key :configuration_snapshots, :projects,
      column: [ :project_id, :organization_id ], primary_key: [ :id, :organization_id ], on_delete: :restrict
    add_foreign_key :configuration_snapshots, :environments,
      column: [ :environment_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :configuration_snapshots, :services,
      column: [ :service_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :configuration_snapshots, :configuration_versions,
      column: [ :project_configuration_version_id, :project_id, :environment_id ],
      primary_key: [ :id, :project_id, :environment_id ], on_delete: :restrict
    add_foreign_key :configuration_snapshots, :configuration_versions,
      column: [ :service_configuration_version_id, :project_id, :environment_id ],
      primary_key: [ :id, :project_id, :environment_id ], on_delete: :restrict
    add_check_constraint :configuration_snapshots, "jsonb_typeof(key_summary) = 'array'", name: "configuration_snapshots_key_summary_array"
    add_check_constraint :configuration_snapshots, "payload_digest ~ '^[0-9a-f]{64}$'", name: "configuration_snapshots_digest_format"

    create_table :deployments, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :project_id, null: false
      table.uuid :service_id, null: false
      table.uuid :environment_id, null: false
      table.uuid :configuration_snapshot_id, null: false
      table.jsonb :source_snapshot, null: false
      table.string :source_digest, null: false, limit: 64
      table.jsonb :runtime_policy_snapshot, null: false
      table.jsonb :build_settings_snapshot, null: false
      table.string :idempotency_key, null: false, limit: 255
      table.uuid :correlation_id, null: false
      table.string :trigger, null: false, limit: 32
      table.string :status, null: false, limit: 32
      table.string :conclusion, limit: 32
      table.integer :lock_version, null: false, default: 0
      table.timestamps
    end

    add_index :deployments, [ :organization_id, :idempotency_key ], unique: true
    add_index :deployments, :correlation_id, unique: true
    add_index :deployments, [ :organization_id, :status, :created_at ]
    add_index :deployments, [ :service_id, :environment_id, :created_at ]
    add_foreign_key :deployments, :projects,
      column: [ :project_id, :organization_id ], primary_key: [ :id, :organization_id ], on_delete: :restrict
    add_foreign_key :deployments, :environments,
      column: [ :environment_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :deployments, :services,
      column: [ :service_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :deployments, :configuration_snapshots,
      column: [ :configuration_snapshot_id, :organization_id, :project_id, :environment_id, :service_id ],
      primary_key: [ :id, :organization_id, :project_id, :environment_id, :service_id ], on_delete: :restrict
    add_check_constraint :deployments, allowed_values("status", STATUSES), name: "deployments_status_allowed"
    add_check_constraint :deployments, "conclusion IS NULL OR " + allowed_values("conclusion", CONCLUSIONS), name: "deployments_conclusion_allowed"
    add_check_constraint :deployments, allowed_values("trigger", TRIGGERS), name: "deployments_trigger_allowed"
    add_check_constraint :deployments, "jsonb_typeof(source_snapshot) = 'object'", name: "deployments_source_snapshot_object"
    add_check_constraint :deployments, "jsonb_typeof(runtime_policy_snapshot) = 'object'", name: "deployments_runtime_policy_snapshot_object"
    add_check_constraint :deployments, "jsonb_typeof(build_settings_snapshot) = 'object'", name: "deployments_build_settings_snapshot_object"
    add_check_constraint :deployments, "source_digest ~ '^[0-9a-f]{64}$'", name: "deployments_source_digest_format"

    create_table :deployment_transitions, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :deployment, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.integer :sequence, null: false
      table.string :from_status, limit: 32
      table.string :to_status, null: false, limit: 32
      table.string :actor_type, null: false, limit: 16
      table.uuid :actor_id
      table.string :cause, null: false, limit: 120
      table.jsonb :error, null: false, default: {}
      table.datetime :occurred_at, null: false
      table.timestamps
    end

    add_index :deployment_transitions, [ :deployment_id, :sequence ], unique: true
    add_check_constraint :deployment_transitions, "sequence > 0", name: "deployment_transitions_sequence_positive"
    add_check_constraint :deployment_transitions, "actor_type = 'user' OR actor_type = 'system'", name: "deployment_transitions_actor_type_allowed"
    add_check_constraint :deployment_transitions, "jsonb_typeof(error) = 'object'", name: "deployment_transitions_error_object"
  end

  private

  def allowed_values(column, values)
    values.map { |value| "#{column} = #{connection.quote(value)}" }.join(" OR ")
  end
end
