class CreateIdentityAndOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :email, null: false, limit: 320
      table.string :name, null: false, limit: 120
      table.timestamps
    end

    add_index :users, "LOWER(email)", unique: true, name: "index_users_on_lower_email"
    add_check_constraint :users, "email = LOWER(BTRIM(email))", name: "users_email_normalized"
    add_check_constraint :users, "BTRIM(name) <> ''", name: "users_name_present"

    create_table :organizations, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :name, null: false, limit: 120
      table.timestamps
    end

    add_check_constraint :organizations, "BTRIM(name) <> ''", name: "organizations_name_present"

    create_table :memberships, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :user, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :role, null: false, limit: 16
      table.timestamps
    end

    add_index :memberships, [ :organization_id, :user_id ], unique: true
    add_index :memberships, [ :organization_id, :role ]
    add_check_constraint :memberships,
      "role IN ('owner', 'admin', 'member')",
      name: "memberships_role_allowed"
  end
end
