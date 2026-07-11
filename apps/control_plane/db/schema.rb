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

ActiveRecord::Schema[8.1].define(version: 2026_07_11_202100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "users", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", limit: 320, null: false
    t.string "name", limit: 120, null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.check_constraint "btrim(name::text) <> ''::text", name: "users_name_present"
    t.check_constraint "email::text = lower(btrim(email::text))", name: "users_email_normalized"
  end

  add_foreign_key "memberships", "organizations", on_delete: :restrict
  add_foreign_key "memberships", "users", on_delete: :restrict
end
