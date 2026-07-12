class CreateAuthenticationRequestAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :authentication_request_attempts, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :email_digest, null: false, limit: 64
      table.string :ip_digest, limit: 64
      table.timestamps
    end

    add_index :authentication_request_attempts, [ :email_digest, :created_at ]
    add_index :authentication_request_attempts, [ :ip_digest, :created_at ]
    add_check_constraint :authentication_request_attempts,
      "email_digest ~ '^[0-9a-f]{64}$'",
      name: "authentication_request_attempts_email_digest_format"
    add_check_constraint :authentication_request_attempts,
      "ip_digest IS NULL OR ip_digest ~ '^[0-9a-f]{64}$'",
      name: "authentication_request_attempts_ip_digest_format"

    create_table :rodauth_login_claims, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.string :token_digest, null: false, limit: 64
      table.timestamps
    end

    add_index :rodauth_login_claims, :token_digest, unique: true
    add_check_constraint :rodauth_login_claims,
      "token_digest ~ '^[0-9a-f]{64}$'",
      name: "rodauth_login_claims_token_digest_format"
  end
end
