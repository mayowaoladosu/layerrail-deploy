require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "Authentication API", type: :request do
  def api_schema(name)
    contract_path = Pathname(
      ENV.fetch("LRAIL_CONTRACTS_DIR", Rails.root.join("../../contracts"))
    ).join("openapi/v1/openapi.yaml")
    @api_document ||= JSONSchemer.openapi(YAML.safe_load_file(contract_path, aliases: true))

    @api_document.schema(name)
  end

  def request_challenge(email: "api-auth@example.com")
    post "/v1/auth/challenges", params: { email: }, as: :json
  end

  def exchange(token)
    post "/v1/auth/sessions", params: { token: }, as: :json
  end

  it "sends a generic one-time challenge response without exposing its token" do
    expect do
      request_challenge
    end.to change(LoginChallenge, :count).by(1)
      .and change(ActionMailer::Base.deliveries, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      "message" => "If the address can sign in, a one-time link has been sent",
      "expires_in" => Authentication::Challenges::DEFAULT_TTL.to_i
    )
    expect(response.body).not_to include("lr_challenge_")
    expect(LoginChallenge.sole.delivered_at).to be_present
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("lr_challenge_")
  end

  it "exchanges one challenge for a schema-valid bearer session and bootstraps the first owner" do
    request_challenge(email: "Founder@Example.com")
    challenge = LoginChallenge.sole
    raw_token = challenge.token

    exchange(raw_token)

    expect(response).to have_http_status(:created)
    expect(api_schema("AuthenticationResult")).to be_valid(response.parsed_body)
    expect(response.parsed_body).to include(
      "token_type" => "Bearer",
      "user" => include("email" => "founder@example.com"),
      "organization" => include("id" => Organization.sole.id)
    )
    expect(response.parsed_body.fetch("access_token")).to start_with("lr_api_")
    expect(challenge.reload).to have_attributes(consumed_at: be_present, token: nil)

    exchange(raw_token)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("invalid_challenge")
  end

  it "returns the current identity and revokes the bearer session" do
    owner = User.create!(email: "auth-me@example.com", name: "Auth Me")
    organization = Organizations::Create.call(principal: owner, name: "Auth Me Organization").organization
    issued = Authentication::Sessions.issue(user: owner, kind: :api, ip: nil, user_agent: nil)
    headers = { "Authorization" => "Bearer #{issued.token}" }

    get "/v1/auth/me", headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(api_schema("CurrentIdentity")).to be_valid(response.parsed_body)
    expect(response.parsed_body).to include(
      "user" => include("id" => owner.id),
      "organizations" => [ include("id" => organization.id) ]
    )

    delete "/v1/auth/session", headers:, as: :json
    expect(response).to have_http_status(:no_content)
    expect(issued.session.reload.revoked_at).to be_present

    get "/v1/auth/me", headers:, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "rate limits silently and validates malformed login input" do
    5.times { request_challenge(email: "rate-api@example.com") }
    delivery_count = ActionMailer::Base.deliveries.count

    request_challenge(email: "rate-api@example.com")
    expect(response).to have_http_status(:accepted)
    expect(ActionMailer::Base.deliveries.count).to eq(delivery_count)
    expect(LoginChallenge.where(email: "rate-api@example.com").count).to eq(5)

    request_challenge(email: "not-an-email")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("validation_failed")

    exchange("invalid")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("invalid_challenge")
  end
end
