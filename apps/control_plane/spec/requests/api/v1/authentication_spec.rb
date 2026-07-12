require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "Rodauth authentication API adapter", type: :request do
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

  it "sends a generic Rodauth link response without exposing its token" do
    expect do
      request_challenge
    end.to change(ActionMailer::Base.deliveries, :count).by(1)
      .and change(User, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      "message" => "If the address can sign in, a one-time link has been sent",
      "expires_in" => RodauthMain::EMAIL_AUTH_TTL
    )
    expect(response.body).not_to include("/auth/verify", "key=")
    expect(last_email_auth_key).to be_present
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_email_auth_keys"
    ).to_i).to eq(1)
  end

  it "exchanges one Rodauth key for a schema-valid bearer session and initial owner" do
    request_challenge(email: "Founder@Example.com")
    key = last_email_auth_key

    exchange(key)

    expect(response).to have_http_status(:created)
    expect(api_schema("AuthenticationResult")).to be_valid(response.parsed_body)
    expect(response.parsed_body).to include(
      "token_type" => "Bearer",
      "user" => include("email" => "founder@example.com"),
      "organization" => include("id" => Organization.sole.id)
    )
    access_token = response.parsed_body.fetch("access_token")
    expect(access_token.split(".").length).to eq(3)
    expect(User.sole).to be_authentication_state_active
    expect(RodauthLoginClaim.sole.token_digest).to eq(Digest::SHA256.hexdigest(key))

    get "/v1/auth/me", headers: { "Authorization" => "Bearer #{access_token}" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("user", "email")).to eq("founder@example.com")

    exchange(key)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("invalid_challenge")
  end

  it "returns the current identity and revokes the Rodauth bearer session" do
    owner = User.create!(email: "auth-me@example.com", name: "Auth Me")
    organization = Organizations::Create.call(principal: owner, name: "Auth Me Organization").organization
    issued = Authentication::RodauthSessions.issue(owner)
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

    get "/v1/auth/me", headers:, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "rate limits silently and validates malformed login input" do
    5.times { request_challenge(email: "rate-api@example.com") }
    attempt_count = AuthenticationRequestAttempt.count
    delivery_count = ActionMailer::Base.deliveries.count

    request_challenge(email: "rate-api@example.com")
    expect(response).to have_http_status(:accepted)
    expect(AuthenticationRequestAttempt.count).to eq(attempt_count)
    expect(ActionMailer::Base.deliveries.count).to eq(delivery_count)

    request_challenge(email: "not-an-email")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("validation_failed")

    exchange("invalid")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("invalid_challenge")
  end

  it "does not reveal whether an unknown identity exists after bootstrap" do
    owner = User.create!(email: "existing-owner@example.com", name: "Existing Owner")
    Organizations::Create.call(principal: owner, name: "Existing Organization")
    deliveries = ActionMailer::Base.deliveries.count

    request_challenge(email: "unknown@example.com")

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.fetch("message")).to include("If the address can sign in")
    expect(ActionMailer::Base.deliveries.count).to eq(deliveries)
    expect(User.find_by(email: "unknown@example.com")).to be_nil
  end
end
