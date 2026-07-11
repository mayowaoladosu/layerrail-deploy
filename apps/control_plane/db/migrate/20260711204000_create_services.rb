class CreateServices < ActiveRecord::Migration[8.1]
  WORKLOAD_TYPES = %w[static web private worker cron job].freeze
  SOURCE_TYPES = %w[git oci].freeze
  LIFECYCLE_STATES = %w[
    active
    deletion_requested
    draining
    deleting_resources
    tombstoned
    permanently_deleted
  ].freeze

  def change
    create_table :services, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :project, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :name, null: false, limit: 120
      table.string :workload_type, null: false, limit: 16
      table.string :source_type, null: false, limit: 8
      table.string :source_reference, null: false, limit: 2048
      table.jsonb :runtime_policy, null: false, default: {}
      table.string :lifecycle_state, null: false, limit: 32, default: "active"
      table.timestamps
    end

    add_index :services, "project_id, LOWER(name)",
      unique: true,
      name: "index_services_on_project_and_lower_name"
    add_index :services, [ :project_id, :workload_type ]
    add_index :services, [ :project_id, :lifecycle_state ]
    add_check_constraint :services, "BTRIM(name) <> ''", name: "services_name_present"
    add_check_constraint :services,
      "source_reference = BTRIM(source_reference) AND source_reference <> ''",
      name: "services_source_reference_normalized"
    add_check_constraint :services, "jsonb_typeof(runtime_policy) = 'object'",
      name: "services_runtime_policy_object"
    add_check_constraint :services, allowed_values("workload_type", WORKLOAD_TYPES),
      name: "services_workload_type_allowed"
    add_check_constraint :services, allowed_values("source_type", SOURCE_TYPES),
      name: "services_source_type_allowed"
    add_check_constraint :services, allowed_values("lifecycle_state", LIFECYCLE_STATES),
      name: "services_lifecycle_state_allowed"
  end

  private

  def allowed_values(column, values)
    values.map { |value| "#{column} = #{connection.quote(value)}" }.join(" OR ")
  end
end
