require "rails_helper"

RSpec.describe "Rodauth API bearer authentication", type: :request do
  def setup_identity
    owner = User.create!(email: "bearer-owner@example.com", name: "Bearer Owner")
    organization = Organizations::Create.call(principal: owner, name: "Bearer Organization").organization

    [ owner, organization ]
  end

  def post_project(organization:, key:, headers: {})
    post "/v1/projects",
      params: {
        organization_id: organization.id,
        name: "Bearer Project #{key}",
        slug: "bearer-project-#{key}"
      },
      headers: { "Idempotency-Key" => key }.merge(headers),
      as: :json
  end

  it "authenticates a live Rodauth JWT without the test-only request seam" do
    owner, organization = setup_identity
    issued = Authentication::RodauthSessions.issue(owner)

    post_project(
      organization:,
      key: "bearer-live",
      headers: { "Authorization" => "Bearer #{issued.token}" }
    )

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("organization_id")).to eq(organization.id)
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys WHERE user_id = '#{owner.id}'"
    ).to_i).to eq(1)
  end

  it "rejects invalid, expired, and revoked bearer tokens" do
    owner, organization = setup_identity
    issued = Authentication::RodauthSessions.issue(owner)

    post_project(
      organization:,
      key: "bearer-invalid",
      headers: { "Authorization" => "Bearer invalid" }
    )
    expect(response).to have_http_status(:unauthorized)

    expired = JWT.encode(
      {
        "session" => { "account_id" => owner.id },
        "iss" => RodauthMain::JWT_ISSUER,
        "aud" => RodauthMain::JWT_AUDIENCE,
        "exp" => 1.minute.ago.to_i
      },
      Rails.application.secret_key_base,
      "HS256"
    )
    post_project(
      organization:,
      key: "bearer-expired",
      headers: { "Authorization" => "Bearer #{expired}" }
    )
    expect(response).to have_http_status(:unauthorized)

    expect(Authentication::RodauthSessions.revoke(issued.token)).to be(true)
    post_project(
      organization:,
      key: "bearer-revoked",
      headers: { "Authorization" => "Bearer #{issued.token}" }
    )
    expect(response).to have_http_status(:unauthorized)
  end

  it "never treats the browser session as API authentication" do
    owner, organization = setup_identity
    sign_in_with_rodauth(owner)

    post_project(organization:, key: "cookie-only")
    expect(response).to have_http_status(:unauthorized)

    post_project(
      organization:,
      key: "cookie-fallback",
      headers: { "Authorization" => "Bearer invalid" }
    )
    expect(response).to have_http_status(:unauthorized)
  end
end
