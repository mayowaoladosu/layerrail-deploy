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

ActiveRecord::Schema[8.1].define(version: 2026_07_11_204000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "environments", id: :uuid, default: nil, force: :cascade do |t|
    t.string "branch", limit: 255
    t.datetime "created_at", null: false
    t.string "kind", limit: 16, null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "project_id", null: false
    t.string "slug", limit: 64, null: false
    t.datetime "updated_at", null: false
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
    t.index ["organization_id", "lifecycle_state"], name: "index_projects_on_organization_id_and_lifecycle_state"
    t.index ["organization_id", "slug"], name: "index_projects_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "projects_name_present"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "projects_lifecycle_state_allowed"
    t.check_constraint "slug::text = lower(btrim(slug::text)) AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text", name: "projects_slug_normalized"
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

  add_foreign_key "environments", "projects", on_delete: :restrict
  add_foreign_key "memberships", "organizations", on_delete: :restrict
  add_foreign_key "memberships", "users", on_delete: :restrict
  add_foreign_key "projects", "organizations", on_delete: :restrict
  add_foreign_key "services", "projects", on_delete: :restrict
end
