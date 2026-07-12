require "rails_helper"

RSpec.describe Authentication::Challenges do
  it "issues a one-time expiring challenge with encrypted token storage" do
    result = described_class.issue(email: " New.User@Example.COM ", ip: "192.0.2.20")
    stored = LoginChallenge.connection.select_value(
      LoginChallenge.sanitize_sql_array([ "SELECT token FROM login_challenges WHERE id = ?", result.challenge.id ])
    )

    expect(result.rate_limited).to be(false)
    expect(result.token).to start_with("lr_challenge_")
    expect(result.challenge).to have_attributes(
      email: "new.user@example.com",
      purpose: "email_login",
      consumed_at: nil,
      expires_at: be > Time.current
    )
    expect(stored).not_to include(result.token)
    expect(result.challenge.inspect).to include("token=[REDACTED]")
    expect(LoginChallenge.columns_hash.fetch("id").default_function).to be_nil
  end

  it "consumes a challenge once and bootstraps only the first organization owner" do
    issued = described_class.issue(email: "founder@example.com", ip: "192.0.2.21")

    result = described_class.complete(
      token: issued.token,
      session_kind: :api,
      ip: "192.0.2.21",
      user_agent: "RSpec Client"
    )

    expect(result.user).to have_attributes(email: "founder@example.com", name: "Founder")
    expect(result.organization).to be_present
    expect(result.organization.memberships.sole).to have_attributes(user: result.user, role: "owner")
    expect(result.token).to start_with("lr_api_")
    expect(issued.challenge.reload).to have_attributes(consumed_at: be_present, token: nil)

    expect do
      described_class.complete(
        token: issued.token,
        session_kind: :api,
        ip: "192.0.2.21",
        user_agent: "RSpec Client"
      )
    end.to raise_error(Authentication::Challenges::InvalidChallenge)
  end

  it "authenticates an existing user without creating another organization" do
    owner = User.create!(email: "existing@example.com", name: "Existing")
    organization = Organizations::Create.call(principal: owner, name: "Existing Organization").organization
    issued = described_class.issue(email: owner.email, ip: "192.0.2.22")

    result = described_class.complete(
      token: issued.token,
      session_kind: :web,
      ip: "192.0.2.22",
      user_agent: "Browser"
    )

    expect(result).to have_attributes(user: owner, organization:)
    expect(result.token).to start_with("lr_web_")
    expect(User.count).to eq(1)
    expect(Organization.count).to eq(1)
  end

  it "does not self-register an unknown identity after bootstrap" do
    owner = User.create!(email: "owner@example.com", name: "Owner")
    Organizations::Create.call(principal: owner, name: "Existing Organization")
    issued = described_class.issue(email: "unknown@example.com", ip: "192.0.2.25")

    expect do
      described_class.complete(
        token: issued.token,
        session_kind: :api,
        ip: nil,
        user_agent: nil
      )
    end.to raise_error(Authentication::Challenges::InvalidChallenge)
    expect(User.find_by(email: "unknown@example.com")).to be_nil
    expect(AuthenticationSession).not_to exist
  end

  it "rate limits repeated email challenges without creating additional secrets" do
    results = 6.times.map do
      described_class.issue(email: "limited@example.com", ip: "192.0.2.23")
    end

    expect(results.first(5)).to all(have_attributes(rate_limited: false))
    expect(results.last).to have_attributes(challenge: nil, token: nil, rate_limited: true)
    expect(LoginChallenge.count).to eq(5)
  end

  it "rejects expired, malformed and wrong-purpose challenges" do
    expired = described_class.issue(
      email: "expired@example.com",
      ip: "192.0.2.24",
      issued_at: 2.minutes.ago,
      expires_at: 1.minute.ago
    )

    expect do
      described_class.complete(
        token: expired.token,
        session_kind: :api,
        ip: nil,
        user_agent: nil
      )
    end.to raise_error(Authentication::Challenges::InvalidChallenge)
    expect do
      described_class.complete(
        token: "lr_challenge_invalid",
        session_kind: :api,
        ip: nil,
        user_agent: nil
      )
    end.to raise_error(Authentication::Challenges::InvalidChallenge)
  end
end
