require "rails_helper"

RSpec.describe "API bearer authentication", type: :request do
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

  it "authenticates a live API token without the test-only request seam" do
    owner, organization = setup_identity
    issued = Authentication::Sessions.issue(
      user: owner,
      kind: :api,
      ip: "192.0.2.30",
      user_agent: "RSpec API"
    )

    post_project(
      organization:,
      key: "bearer-live",
      headers: { "Authorization" => "Bearer #{issued.token}" }
    )

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("organization_id")).to eq(organization.id)
    expect(issued.session.reload.last_used_at).to be_present
  end

  it "rejects invalid and revoked bearer tokens" do
    owner, organization = setup_identity
    issued = Authentication::Sessions.issue(user: owner, kind: :api, ip: nil, user_agent: nil)

    post_project(
      organization:,
      key: "bearer-invalid",
      headers: { "Authorization" => "Bearer invalid" }
    )
    expect(response).to have_http_status(:unauthorized)

    Authentication::Sessions.revoke(session: issued.session, reason: "user_logout")
    post_project(
      organization:,
      key: "bearer-revoked",
      headers: { "Authorization" => "Bearer #{issued.token}" }
    )
    expect(response).to have_http_status(:unauthorized)
  end

  it "does not accept a web cookie or fall back to it after a bad bearer header" do
    owner, organization = setup_identity
    issued = Authentication::Sessions.issue(user: owner, kind: :web, ip: nil, user_agent: nil)
    cookie = "#{Authentication::Middleware::COOKIE_NAME}=#{issued.token}"

    post_project(
      organization:,
      key: "cookie-only",
      headers: { "Cookie" => cookie }
    )
    expect(response).to have_http_status(:unauthorized)

    post_project(
      organization:,
      key: "cookie-fallback",
      headers: { "Cookie" => cookie, "Authorization" => "Bearer invalid" }
    )
    expect(response).to have_http_status(:unauthorized)
  end
end
