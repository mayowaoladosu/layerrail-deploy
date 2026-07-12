class ReplaceCustomAuthenticationWithRodauth < ActiveRecord::Migration[8.1]
  def up
    rename_table :authentication_sessions, :legacy_authentication_sessions
    rename_table :login_challenges, :legacy_login_challenges

    add_column :users, :authentication_state, :string,
      null: false,
      default: "active",
      limit: 32
    add_column :users, :password_hash, :string, limit: 255
    add_index :users, :authentication_state
    add_check_constraint :users,
      "authentication_state IN ('active', 'bootstrap_candidate', 'blocked')",
      name: "users_authentication_state_allowed"

    create_table :user_email_auth_keys, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :key, null: false
      table.datetime :deadline, null: false
      table.datetime :email_last_sent, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_foreign_key :user_email_auth_keys, :users,
      column: :id,
      on_delete: :cascade

    create_table :user_active_session_keys, id: false do |table|
      table.references :user,
        null: false,
        type: :uuid,
        foreign_key: { on_delete: :cascade }
      table.string :session_id, null: false
      table.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      table.datetime :last_use, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    execute <<~SQL.squish
      ALTER TABLE user_active_session_keys
      ADD PRIMARY KEY (user_id, session_id)
    SQL

    create_table :user_identities, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :user,
        null: false,
        type: :uuid,
        foreign_key: { on_delete: :cascade }
      table.string :provider, null: false, limit: 64
      table.string :uid, null: false, limit: 255
      table.timestamps
    end
    add_index :user_identities, [ :provider, :uid ], unique: true
    add_index :user_identities, [ :user_id, :provider ], unique: true
  end

  def down
    drop_table :user_identities
    drop_table :user_active_session_keys
    drop_table :user_email_auth_keys
    remove_check_constraint :users, name: "users_authentication_state_allowed"
    remove_index :users, :authentication_state
    remove_column :users, :password_hash
    remove_column :users, :authentication_state

    rename_table :legacy_login_challenges, :login_challenges
    rename_table :legacy_authentication_sessions, :authentication_sessions
  end
end
