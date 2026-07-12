require "rails_helper"

RSpec.describe Authentication::RodauthSessions do
  def create_owner
    owner = User.create!(email: "session-owner@example.com", name: "Session Owner")
    Organizations::Create.call(principal: owner, name: "Session Organization")
    owner
  end

  it "issues a signed, expiring JWT backed by a revocable Rodauth active session" do
    user = create_owner
    result = described_class.issue(user)
    payload = JWT.decode(
      result.token,
      Rails.application.secret_key_base,
      true,
      algorithm: "HS256",
      iss: RodauthMain::JWT_ISSUER,
      verify_iss: true,
      aud: RodauthMain::JWT_AUDIENCE,
      verify_aud: true
    ).first

    expect(payload).to include(
      "iss" => RodauthMain::JWT_ISSUER,
      "aud" => RodauthMain::JWT_AUDIENCE
    )
    expect(payload.fetch("session").fetch("account_id")).to eq(user.id)
    expect(Time.zone.at(payload.fetch("exp"))).to be_within(2.seconds).of(result.expires_at)
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys WHERE user_id = '#{user.id}'"
    ).to_i).to eq(1)
  end

  it "durably revokes a bearer session and never restores it" do
    user = create_owner
    result = described_class.issue(user)

    expect(described_class.revoke(result.token)).to be(true)
    expect(described_class.revoke(result.token)).to be(false)
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys WHERE user_id = '#{user.id}'"
    ).to_i).to eq(0)
  end
end
