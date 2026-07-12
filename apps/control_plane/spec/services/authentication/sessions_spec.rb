require "rails_helper"

RSpec.describe Authentication::Sessions do
  def create_user
    owner = User.create!(email: "session-owner@example.com", name: "Session Owner")
    Organizations::Create.call(principal: owner, name: "Session Organization")
    owner
  end

  it "issues an opaque kind-bound session while persisting only its digest" do
    user = create_user

    result = described_class.issue(
      user:,
      kind: :api,
      ip: "192.0.2.10",
      user_agent: "RSpec Client"
    )

    expect(result.token).to start_with("lr_api_")
    expect(result.session).to have_attributes(
      user:,
      kind: "api",
      assurance_level: "single_factor",
      revoked_at: nil,
      expires_at: be > Time.current
    )
    expect(result.session.token_digest).to eq(Digest::SHA256.hexdigest(result.token))
    expect(result.session.attributes.to_s).not_to include(result.token)
    expect(result.session.inspect).to include("token=[REDACTED]")
    expect(AuthenticationSession.columns_hash.fetch("id").default_function).to be_nil
  end

  it "authenticates only an active session of the requested kind" do
    user = create_user
    api = described_class.issue(user:, kind: :api, ip: nil, user_agent: nil)
    web = described_class.issue(user:, kind: :web, ip: nil, user_agent: nil)

    expect(described_class.authenticate(token: api.token, kind: :api)).to have_attributes(user:, session: api.session)
    expect(described_class.authenticate(token: api.token, kind: :web)).to be_nil
    expect(described_class.authenticate(token: web.token, kind: :web)).to have_attributes(user:, session: web.session)
    expect(described_class.authenticate(token: "lr_api_invalid", kind: :api)).to be_nil
  end

  it "rejects expired and revoked sessions and never restores them" do
    user = create_user
    expired = described_class.issue(
      user:,
      kind: :api,
      ip: nil,
      user_agent: nil,
      issued_at: 2.minutes.ago,
      expires_at: 1.minute.ago
    )
    active = described_class.issue(user:, kind: :api, ip: nil, user_agent: nil)

    expect(described_class.authenticate(token: expired.token, kind: :api)).to be_nil
    described_class.revoke(session: active.session, reason: "user_logout")

    expect(described_class.authenticate(token: active.token, kind: :api)).to be_nil
    expect(active.session.reload).to have_attributes(revoked_at: be_present, revoked_reason: "user_logout")
    expect do
      active.session.update!(revoked_at: nil, revoked_reason: nil)
    end.to raise_error(ActiveRecord::RecordNotSaved)
  end
end
