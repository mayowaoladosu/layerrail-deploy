class CreateAuthenticationSessionsAndLoginChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :authentication_sessions, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :user, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :kind, null: false, limit: 16
      table.string :assurance_level, null: false, limit: 32
      table.string :token_digest, null: false, limit: 64
      table.datetime :issued_at, null: false
      table.datetime :expires_at, null: false
      table.datetime :last_used_at
      table.datetime :revoked_at
      table.string :revoked_reason, limit: 120
      table.string :ip_digest, limit: 64
      table.string :user_agent_digest, limit: 64
      table.timestamps
    end

    add_index :authentication_sessions, :token_digest, unique: true
    add_index :authentication_sessions, [ :user_id, :kind, :revoked_at, :expires_at ], name: "index_authentication_sessions_for_user"
    add_check_constraint :authentication_sessions,
      "kind = 'web' OR kind = 'api'",
      name: "authentication_sessions_kind_allowed"
    add_check_constraint :authentication_sessions,
      "assurance_level = 'single_factor' OR assurance_level = 'multi_factor'",
      name: "authentication_sessions_assurance_level_allowed"
    add_check_constraint :authentication_sessions,
      "token_digest ~ '^[0-9a-f]{64}$'",
      name: "authentication_sessions_token_digest_format"
    add_check_constraint :authentication_sessions,
      "expires_at > issued_at",
      name: "authentication_sessions_expiry_after_issue"
    add_check_constraint :authentication_sessions,
      "(revoked_at IS NULL AND revoked_reason IS NULL) OR " \
        "(revoked_at IS NOT NULL AND revoked_reason IS NOT NULL AND " \
        "revoked_reason = btrim(revoked_reason) AND revoked_reason <> '')",
      name: "authentication_sessions_revocation_consistent"
    add_check_constraint :authentication_sessions,
      "ip_digest IS NULL OR ip_digest ~ '^[0-9a-f]{64}$'",
      name: "authentication_sessions_ip_digest_format"
    add_check_constraint :authentication_sessions,
      "user_agent_digest IS NULL OR user_agent_digest ~ '^[0-9a-f]{64}$'",
      name: "authentication_sessions_user_agent_digest_format"

    create_table :login_challenges, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :email, null: false, limit: 320
      table.string :purpose, null: false, limit: 32
      table.text :token
      table.string :token_digest, null: false, limit: 64
      table.string :requested_ip_digest, limit: 64
      table.datetime :expires_at, null: false
      table.datetime :delivered_at
      table.datetime :consumed_at
      table.timestamps
    end

    add_index :login_challenges, :token_digest, unique: true
    add_index :login_challenges, [ :email, :created_at ]
    add_index :login_challenges, [ :requested_ip_digest, :created_at ]
    add_check_constraint :login_challenges,
      "email = lower(btrim(email)) AND email <> ''",
      name: "login_challenges_email_normalized"
    add_check_constraint :login_challenges,
      "purpose = 'email_login'",
      name: "login_challenges_purpose_allowed"
    add_check_constraint :login_challenges,
      "token_digest ~ '^[0-9a-f]{64}$'",
      name: "login_challenges_token_digest_format"
    add_check_constraint :login_challenges,
      "requested_ip_digest IS NULL OR requested_ip_digest ~ '^[0-9a-f]{64}$'",
      name: "login_challenges_ip_digest_format"
    add_check_constraint :login_challenges,
      "expires_at > created_at",
      name: "login_challenges_expiry_after_creation"
    add_check_constraint :login_challenges,
      "(consumed_at IS NULL AND token IS NOT NULL) OR (consumed_at IS NOT NULL AND token IS NULL)",
      name: "login_challenges_consumption_consistent"
  end
end
