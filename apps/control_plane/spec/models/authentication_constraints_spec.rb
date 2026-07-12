require "rails_helper"

RSpec.describe "Authentication persistence constraints" do
  it "uses UUIDv7 without database token defaults or plaintext session secrets" do
    owner = User.create!(email: "auth-constraints@example.com", name: "Auth Constraints")
    Organizations::Create.call(principal: owner, name: "Auth Constraints")
    session = Authentication::Sessions.issue(user: owner, kind: :api, ip: nil, user_agent: nil)
    challenge = Authentication::Challenges.issue(email: owner.email, ip: nil)
    stored_challenge = LoginChallenge.connection.select_value(
      LoginChallenge.sanitize_sql_array([ "SELECT token FROM login_challenges WHERE id = ?", challenge.challenge.id ])
    )

    expect([ session.session.id, challenge.challenge.id ]).to all(
      match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    )
    expect([ AuthenticationSession, LoginChallenge ].map { |model| model.columns_hash.fetch("id").default_function })
      .to all(be_nil)
    expect(AuthenticationSession.column_names).not_to include("token")
    expect(stored_challenge).not_to include(challenge.token)
  end

  it "rejects inconsistent revocation and challenge consumption in PostgreSQL" do
    owner = User.create!(email: "auth-state@example.com", name: "Auth State")
    timestamp = Time.current

    expect do
      AuthenticationSession.insert_all!([ {
        id: SecureRandom.uuid_v7,
        user_id: owner.id,
        kind: "api",
        assurance_level: "single_factor",
        token_digest: "a" * 64,
        issued_at: timestamp,
        expires_at: timestamp + 1.hour,
        revoked_at: timestamp,
        revoked_reason: nil,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)

    expect do
      LoginChallenge.insert_all!([ {
        id: SecureRandom.uuid_v7,
        email: owner.email,
        purpose: "email_login",
        token: "encrypted-looking-value",
        token_digest: "b" * 64,
        expires_at: timestamp + 15.minutes,
        consumed_at: timestamp,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "rejects a session for an unknown user in PostgreSQL" do
    timestamp = Time.current

    expect do
      AuthenticationSession.insert_all!([ {
        id: SecureRandom.uuid_v7,
        user_id: SecureRandom.uuid_v7,
        kind: "api",
        assurance_level: "single_factor",
        token_digest: "c" * 64,
        issued_at: timestamp,
        expires_at: timestamp + 1.hour,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
