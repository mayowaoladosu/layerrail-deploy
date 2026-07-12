require "rails_helper"

RSpec.describe "Rodauth persistence constraints" do
  it "stores only HMAC-protected active-session identifiers" do
    owner = User.create!(email: "auth-constraints@example.com", name: "Auth Constraints")
    Organizations::Create.call(principal: owner, name: "Auth Constraints")
    issued = Authentication::RodauthSessions.issue(owner)
    payload = JWT.decode(issued.token, nil, false).first.fetch("session")
    raw_session_id = payload.fetch("active_session_id")
    stored_session_id = ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array([
        "SELECT session_id FROM user_active_session_keys WHERE user_id = ?",
        owner.id
      ])
    )

    expect(stored_session_id).to match(/\A[A-Za-z0-9_-]{43}\z/)
    expect(stored_session_id).not_to eq(raw_session_id)
    expect(issued.token).not_to include(stored_session_id)
  end

  it "uses application-assigned UUIDv7 identifiers for security records" do
    attempt = AuthenticationRequestAttempt.create!(
      email_digest: "a" * 64,
      ip_digest: "b" * 64
    )
    claim = RodauthLoginClaim.create!(token_digest: "c" * 64)

    expect([ attempt.id, claim.id ]).to all(
      match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    )
    expect([
      AuthenticationRequestAttempt,
      RodauthLoginClaim
    ].map { |model| model.columns_hash.fetch("id").default_function }).to all(be_nil)
  end

  it "rejects invalid security digests and unknown-user sessions in PostgreSQL" do
    timestamp = Time.current

    expect do
      ApplicationRecord.transaction(requires_new: true) do
        AuthenticationRequestAttempt.insert_all!([ {
          id: SecureRandom.uuid_v7,
          email_digest: "invalid",
          created_at: timestamp,
          updated_at: timestamp
        } ])
      end
    end.to raise_error(ActiveRecord::StatementInvalid)

    expect do
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.execute(<<~SQL.squish)
          INSERT INTO user_active_session_keys (user_id, session_id, created_at, last_use)
          VALUES ('#{SecureRandom.uuid_v7}', '#{"d" * 64}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "archives the replaced custom tables instead of keeping them in the auth path" do
    tables = ApplicationRecord.connection.tables

    expect(tables).to include(
      "legacy_authentication_sessions",
      "legacy_login_challenges",
      "user_email_auth_keys",
      "user_active_session_keys"
    )
    expect(defined?(AuthenticationSession)).to be_nil
    expect(defined?(LoginChallenge)).to be_nil
  end
end
