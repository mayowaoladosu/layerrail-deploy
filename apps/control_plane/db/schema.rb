# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_11_212000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "configuration_versions", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.uuid "environment_id", null: false
    t.jsonb "key_summary", null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.text "payload_json", null: false
    t.uuid "project_id", null: false
    t.string "scope_key", limit: 255, null: false
    t.uuid "service_id"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["created_by_id"], name: "index_configuration_versions_on_created_by_id"
    t.index ["environment_id", "scope_key", "version"], name: "index_configuration_versions_on_environment_scope_version", unique: true
    t.index ["organization_id", "project_id", "environment_id"], name: "index_configuration_versions_on_tenant_scope"
    t.index ["service_id", "environment_id"], name: "index_configuration_versions_on_service_id_and_environment_id"
    t.check_constraint "jsonb_typeof(key_summary) = 'array'::text", name: "configuration_versions_key_summary_array"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "configuration_versions_digest_format"
    t.check_constraint "service_id IS NULL AND scope_key::text = 'project'::text OR service_id IS NOT NULL AND scope_key::text = ('service:'::text || service_id::text)", name: "configuration_versions_scope_matches_service"
    t.check_constraint "version > 0", name: "configuration_versions_version_positive"
  end

  create_table "environments", id: :uuid, default: nil, force: :cascade do |t|
    t.string "branch", limit: 255
    t.datetime "created_at", null: false
    t.string "kind", limit: 16, null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "project_id", null: false
    t.string "slug", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id"], name: "index_environments_on_id_and_project_id", unique: true
    t.index ["project_id", "branch"], name: "index_environments_on_project_id_and_branch", unique: true, where: "(branch IS NOT NULL)"
    t.index ["project_id", "lifecycle_state"], name: "index_environments_on_project_id_and_lifecycle_state"
    t.index ["project_id", "slug"], name: "index_environments_on_project_id_and_slug", unique: true
    t.index ["project_id"], name: "index_environments_on_one_production_per_project", unique: true, where: "((kind)::text = 'production'::text)"
    t.index ["project_id"], name: "index_environments_on_one_staging_per_project", unique: true, where: "((kind)::text = 'staging'::text)"
    t.index ["project_id"], name: "index_environments_on_project_id"
    t.check_constraint "branch IS NULL OR branch::text = btrim(branch::text) AND branch::text <> ''::text", name: "environments_branch_normalized"
    t.check_constraint "btrim(name::text) <> ''::text", name: "environments_name_present"
    t.check_constraint "kind::text = 'production'::text OR kind::text = 'staging'::text OR kind::text = 'custom'::text", name: "environments_kind_allowed"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "environments_lifecycle_state_allowed"
    t.check_constraint "slug::text = lower(btrim(slug::text)) AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text", name: "environments_slug_normalized"
  end

  create_table "git_installations", id: :uuid, default: nil, force: :cascade do |t|
    t.string "account_id", limit: 255, null: false
    t.string "account_login", limit: 255, null: false
    t.string "account_type", limit: 32, null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.jsonb "permissions", default: {}, null: false
    t.string "provider", limit: 32, null: false
    t.string "provider_installation_id", limit: 255, null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "organization_id"], name: "index_git_installations_on_id_and_organization_id", unique: true
    t.index ["organization_id", "provider"], name: "index_git_installations_on_organization_id_and_provider"
    t.index ["organization_id"], name: "index_git_installations_on_organization_id"
    t.index ["provider", "provider_installation_id"], name: "idx_on_provider_provider_installation_id_eb69f10f93", unique: true
    t.check_constraint "account_type::text = 'organization'::text OR account_type::text = 'user'::text", name: "git_installations_account_type_allowed"
    t.check_constraint "jsonb_typeof(permissions) = 'object'::text", name: "git_installations_permissions_object"
    t.check_constraint "provider::text = 'github'::text", name: "git_installations_provider_allowed"
    t.check_constraint "status::text = 'active'::text OR status::text = 'suspended'::text OR status::text = 'disconnected'::text", name: "git_installations_status_allowed"
  end

  create_table "git_webhook_inboxes", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", null: false
    t.string "delivery_id", limit: 255, null: false
    t.string "event_type", limit: 120, null: false
    t.uuid "git_installation_id", null: false
    t.datetime "occurred_at", null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.datetime "processed_at"
    t.string "provider", limit: 32, null: false
    t.string "provider_repository_id", limit: 255
    t.text "safe_error"
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["git_installation_id", "provider_repository_id"], name: "idx_on_git_installation_id_provider_repository_id_43d077995b"
    t.index ["organization_id", "status", "created_at"], name: "idx_on_organization_id_status_created_at_b0e5eedb6a"
    t.index ["provider", "delivery_id"], name: "index_git_webhook_inboxes_on_provider_and_delivery_id", unique: true
    t.check_constraint "jsonb_typeof(data) = 'object'::text", name: "git_webhook_inboxes_data_object"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "git_webhook_inboxes_digest_format"
    t.check_constraint "provider::text = 'github'::text", name: "git_webhook_inboxes_provider_allowed"
    t.check_constraint "status::text = 'pending'::text OR status::text = 'processed'::text OR status::text = 'failed'::text", name: "git_webhook_inboxes_status_allowed"
  end

  create_table "idempotency_records", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", limit: 255, null: false
    t.string "operation", limit: 120, null: false
    t.uuid "organization_id", null: false
    t.string "request_fingerprint", limit: 64, null: false
    t.uuid "resource_id"
    t.string "resource_type", limit: 120
    t.jsonb "response_body", null: false
    t.integer "response_status", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_idempotency_records_on_organization_id_and_key", unique: true
    t.index ["organization_id"], name: "index_idempotency_records_on_organization_id"
    t.index ["resource_type", "resource_id"], name: "index_idempotency_records_on_resource_type_and_resource_id"
    t.check_constraint "jsonb_typeof(response_body) = 'object'::text", name: "idempotency_records_response_object"
    t.check_constraint "key::text = btrim(key::text) AND key::text <> ''::text", name: "idempotency_records_key_normalized"
    t.check_constraint "operation::text = btrim(operation::text) AND operation::text <> ''::text", name: "idempotency_records_operation_normalized"
    t.check_constraint "request_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "idempotency_records_fingerprint_format"
    t.check_constraint "response_status >= 200 AND response_status <= 599", name: "idempotency_records_status_range"
  end

  create_table "memberships", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "role", limit: 16, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["organization_id", "role"], name: "index_memberships_on_organization_id_and_role"
    t.index ["organization_id", "user_id"], name: "index_memberships_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.check_constraint "role::text = 'owner'::text OR role::text = 'admin'::text OR role::text = 'member'::text", name: "memberships_role_allowed"
  end

  create_table "organizations", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", limit: 120, null: false
    t.datetime "updated_at", null: false
    t.check_constraint "btrim(name::text) <> ''::text", name: "organizations_name_present"
  end

  create_table "projects", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "organization_id", null: false
    t.string "slug", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index "organization_id, lower((name)::text)", name: "index_projects_on_organization_and_lower_name", unique: true
    t.index ["id", "organization_id"], name: "index_projects_on_id_and_organization_id", unique: true
    t.index ["organization_id", "lifecycle_state"], name: "index_projects_on_organization_id_and_lifecycle_state"
    t.index ["organization_id", "slug"], name: "index_projects_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "projects_name_present"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "projects_lifecycle_state_allowed"
    t.check_constraint "slug::text = lower(btrim(slug::text)) AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text", name: "projects_slug_normalized"
  end

  create_table "repository_connections", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_branch", limit: 255, null: false
    t.string "full_name", limit: 255, null: false
    t.uuid "git_installation_id", null: false
    t.string "name", limit: 255, null: false
    t.uuid "organization_id", null: false
    t.string "owner", limit: 255, null: false
    t.boolean "private", null: false
    t.uuid "project_id", null: false
    t.string "provider_repository_id", limit: 255, null: false
    t.uuid "service_id", null: false
    t.string "status", limit: 32, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["git_installation_id", "provider_repository_id"], name: "index_repository_connections_on_installation_and_repository", unique: true
    t.index ["id", "organization_id"], name: "index_repository_connections_on_id_and_organization_id", unique: true
    t.index ["organization_id", "status"], name: "index_repository_connections_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_repository_connections_on_organization_id"
    t.index ["project_id", "organization_id"], name: "index_repository_connections_on_project_id_and_organization_id"
    t.index ["service_id", "project_id"], name: "index_repository_connections_on_service_id_and_project_id"
    t.index ["service_id"], name: "index_repository_connections_on_service_id", unique: true
    t.check_constraint "status::text = 'active'::text OR status::text = 'removed'::text OR status::text = 'disconnected'::text", name: "repository_connections_status_allowed"
  end

  create_table "services", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "project_id", null: false
    t.jsonb "runtime_policy", default: {}, null: false
    t.string "source_reference", limit: 2048, null: false
    t.string "source_type", limit: 8, null: false
    t.datetime "updated_at", null: false
    t.string "workload_type", limit: 16, null: false
    t.index "project_id, lower((name)::text)", name: "index_services_on_project_and_lower_name", unique: true
    t.index ["id", "project_id"], name: "index_services_on_id_and_project_id", unique: true
    t.index ["project_id", "lifecycle_state"], name: "index_services_on_project_id_and_lifecycle_state"
    t.index ["project_id", "workload_type"], name: "index_services_on_project_id_and_workload_type"
    t.index ["project_id"], name: "index_services_on_project_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "services_name_present"
    t.check_constraint "jsonb_typeof(runtime_policy) = 'object'::text", name: "services_runtime_policy_object"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "services_lifecycle_state_allowed"
    t.check_constraint "source_reference::text = btrim(source_reference::text) AND source_reference::text <> ''::text", name: "services_source_reference_normalized"
    t.check_constraint "source_type::text = 'git'::text OR source_type::text = 'oci'::text", name: "services_source_type_allowed"
    t.check_constraint "workload_type::text = 'static'::text OR workload_type::text = 'web'::text OR workload_type::text = 'private'::text OR workload_type::text = 'worker'::text OR workload_type::text = 'cron'::text OR workload_type::text = 'job'::text", name: "services_workload_type_allowed"
  end

  create_table "users", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", limit: 320, null: false
    t.string "name", limit: 120, null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.check_constraint "btrim(name::text) <> ''::text", name: "users_name_present"
    t.check_constraint "email::text = lower(btrim(email::text))", name: "users_email_normalized"
  end

  add_foreign_key "configuration_versions", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "environments", "projects", on_delete: :restrict
  add_foreign_key "git_installations", "organizations", on_delete: :restrict
  add_foreign_key "git_webhook_inboxes", "git_installations", column: ["git_installation_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "idempotency_records", "organizations", on_delete: :restrict
  add_foreign_key "memberships", "organizations", on_delete: :restrict
  add_foreign_key "memberships", "users", on_delete: :restrict
  add_foreign_key "projects", "organizations", on_delete: :restrict
  add_foreign_key "repository_connections", "git_installations", column: ["git_installation_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "repository_connections", "organizations", on_delete: :restrict
  add_foreign_key "repository_connections", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "repository_connections", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "services", "projects", on_delete: :restrict
end
