class CreateBuildsRevisionsAndAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :builds, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.references :deployment, null: false, type: :uuid
      table.integer :attempt, null: false
      table.string :idempotency_key, null: false, limit: 255
      table.string :status, null: false, limit: 32
      table.string :artifact_digest, limit: 71
      table.jsonb :evidence, null: false, default: {}
      table.datetime :started_at, null: false
      table.datetime :finished_at
      table.integer :lock_version, null: false, default: 0
      table.timestamps
    end

    add_index :builds, [ :deployment_id, :attempt ], unique: true
    add_index :builds, [ :deployment_id, :idempotency_key ], unique: true
    add_index :builds,
      [ :id, :deployment_id, :organization_id, :artifact_digest ],
      unique: true,
      name: "index_builds_on_revision_identity"
    add_index :builds, [ :organization_id, :status, :created_at ]
    add_index :deployments,
      [ :id, :organization_id ],
      unique: true,
      name: "index_deployments_on_tenant_identity"
    add_index :deployments,
      [ :id, :organization_id, :project_id, :service_id, :environment_id, :configuration_snapshot_id ],
      unique: true,
      name: "index_deployments_on_tenant_resource_identity"
    add_index :deployments,
      [ :id, :correlation_id ],
      unique: true,
      name: "index_deployments_on_transition_identity"
    add_column :deployment_transitions, :correlation_id, :uuid
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE deployment_transitions
          SET correlation_id = deployments.correlation_id
          FROM deployments
          WHERE deployments.id = deployment_transitions.deployment_id
        SQL
      end
    end
    change_column_null :deployment_transitions, :correlation_id, false
    add_index :deployment_transitions, :correlation_id
    add_foreign_key :deployment_transitions, :deployments,
      column: [ :deployment_id, :correlation_id ],
      primary_key: [ :id, :correlation_id ],
      on_delete: :restrict
    add_foreign_key :builds, :deployments,
      column: [ :deployment_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
    add_check_constraint :builds, "attempt > 0", name: "builds_attempt_positive"
    add_check_constraint :builds, "status = 'running' OR status = 'succeeded' OR status = 'failed' OR status = 'canceled'", name: "builds_status_allowed"
    add_check_constraint :builds, "artifact_digest IS NULL OR artifact_digest ~ '^sha256:[0-9a-f]{64}$'", name: "builds_artifact_digest_format"
    add_check_constraint :builds, "jsonb_typeof(evidence) = 'object'", name: "builds_evidence_object"
    add_check_constraint :builds, "idempotency_key = btrim(idempotency_key) AND idempotency_key <> ''", name: "builds_idempotency_key_normalized"
    add_check_constraint :builds,
      "(status = 'running' AND artifact_digest IS NULL AND finished_at IS NULL) OR " \
        "(status = 'succeeded' AND artifact_digest IS NOT NULL AND finished_at IS NOT NULL) OR " \
        "(status IN ('failed', 'canceled') AND artifact_digest IS NULL AND finished_at IS NOT NULL)",
      name: "builds_lifecycle_consistent"

    create_table :revisions, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :project_id, null: false
      table.uuid :service_id, null: false
      table.uuid :environment_id, null: false
      table.references :deployment, null: false, type: :uuid
      table.references :build, null: false, type: :uuid, index: { unique: true }
      table.references :configuration_snapshot, null: false, type: :uuid
      table.string :artifact_digest, null: false, limit: 71
      table.jsonb :runtime_policy_snapshot, null: false
      table.string :status, null: false, limit: 32
      table.jsonb :readiness, null: false, default: {}
      table.string :region, null: false, limit: 64
      table.string :cell, null: false, limit: 64
      table.datetime :ready_at
      table.integer :lock_version, null: false, default: 0
      table.timestamps
    end

    add_index :revisions, [ :id, :organization_id, :project_id, :service_id, :environment_id ], unique: true, name: "index_revisions_on_tenant_resource_identity"
    add_index :revisions,
      [ :id, :organization_id, :project_id, :service_id, :environment_id, :status ],
      unique: true,
      name: "index_revisions_on_ready_alias_identity"
    add_index :revisions, [ :service_id, :environment_id, :status, :created_at ]
    add_check_constraint :revisions, "artifact_digest ~ '^sha256:[0-9a-f]{64}$'", name: "revisions_artifact_digest_format"
    add_check_constraint :revisions, "status = 'candidate' OR status = 'ready' OR status = 'retired'", name: "revisions_status_allowed"
    add_check_constraint :revisions, "jsonb_typeof(runtime_policy_snapshot) = 'object'", name: "revisions_runtime_policy_object"
    add_check_constraint :revisions, "jsonb_typeof(readiness) = 'object'", name: "revisions_readiness_object"
    add_check_constraint :revisions,
      "(status = 'candidate' AND ready_at IS NULL) OR (status IN ('ready', 'retired') AND ready_at IS NOT NULL)",
      name: "revisions_lifecycle_consistent"
    add_check_constraint :revisions, "region = btrim(region) AND region <> ''", name: "revisions_region_normalized"
    add_check_constraint :revisions, "cell = btrim(cell) AND cell <> ''", name: "revisions_cell_normalized"
    add_foreign_key :revisions, :projects, column: [ :project_id, :organization_id ], primary_key: [ :id, :organization_id ], on_delete: :restrict
    add_foreign_key :revisions, :environments, column: [ :environment_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :revisions, :services, column: [ :service_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :revisions, :deployments,
      column: [ :deployment_id, :organization_id, :project_id, :service_id, :environment_id, :configuration_snapshot_id ],
      primary_key: [ :id, :organization_id, :project_id, :service_id, :environment_id, :configuration_snapshot_id ],
      on_delete: :restrict
    add_foreign_key :revisions, :builds,
      column: [ :build_id, :deployment_id, :organization_id, :artifact_digest ],
      primary_key: [ :id, :deployment_id, :organization_id, :artifact_digest ],
      on_delete: :restrict
    add_foreign_key :revisions, :configuration_snapshots,
      column: [ :configuration_snapshot_id, :organization_id, :project_id, :environment_id, :service_id ],
      primary_key: [ :id, :organization_id, :project_id, :environment_id, :service_id ],
      on_delete: :restrict

    create_table :aliases, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :project_id, null: false
      table.uuid :service_id, null: false
      table.uuid :environment_id, null: false
      table.string :alias_type, null: false, limit: 32
      table.string :name, null: false, limit: 255
      table.uuid :current_revision_id, null: false
      table.string :current_revision_status, null: false, limit: 32
      table.uuid :previous_revision_id
      table.string :previous_revision_status, limit: 32
      table.integer :lock_version, null: false, default: 0
      table.timestamps
    end

    add_index :aliases, [ :service_id, :alias_type, :name ], unique: true
    add_index :aliases, [ :organization_id, :project_id, :environment_id ]
    add_check_constraint :aliases, "alias_type = 'environment' OR alias_type = 'branch'", name: "aliases_type_allowed"
    add_check_constraint :aliases, "name = btrim(name) AND name <> ''", name: "aliases_name_normalized"
    add_check_constraint :aliases,
      "previous_revision_id IS NULL OR previous_revision_id <> current_revision_id",
      name: "aliases_revisions_distinct"
    add_check_constraint :aliases, "current_revision_status = 'ready'", name: "aliases_current_revision_ready"
    add_check_constraint :aliases,
      "(previous_revision_id IS NULL AND previous_revision_status IS NULL) OR " \
        "(previous_revision_id IS NOT NULL AND previous_revision_status = 'ready')",
      name: "aliases_previous_revision_ready"
    add_foreign_key :aliases, :projects, column: [ :project_id, :organization_id ], primary_key: [ :id, :organization_id ], on_delete: :restrict
    add_foreign_key :aliases, :environments, column: [ :environment_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :aliases, :services, column: [ :service_id, :project_id ], primary_key: [ :id, :project_id ], on_delete: :restrict
    add_foreign_key :aliases, :revisions,
      column: [ :current_revision_id, :organization_id, :project_id, :service_id, :environment_id, :current_revision_status ],
      primary_key: [ :id, :organization_id, :project_id, :service_id, :environment_id, :status ], on_delete: :restrict
    add_foreign_key :aliases, :revisions,
      column: [ :previous_revision_id, :organization_id, :project_id, :service_id, :environment_id, :previous_revision_status ],
      primary_key: [ :id, :organization_id, :project_id, :service_id, :environment_id, :status ], on_delete: :restrict
  end
end
