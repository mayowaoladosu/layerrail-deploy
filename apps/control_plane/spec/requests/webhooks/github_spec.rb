require "rails_helper"

RSpec.describe "POST /webhooks/github", type: :request do
  def signature(body)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}"
  end

  it "acknowledges a verified delivery after durable inbox persistence" do
    owner = User.create!(email: "webhook-request@example.com", name: "Webhook")
    organization = Organizations::Create.call(principal: owner, name: "Webhook Request").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    provider = build_fake_git_provider
    GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    )
    body = JSON.generate(
      installation: { id: "installation-1" },
      repository: { id: "repository-1" },
      ref: "refs/heads/main",
      before: "aaaaaaaa",
      after: "bbbbbbbb",
      pusher: { id: "provider-user-1" }
    )

    post "/webhooks/github",
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-GitHub-Delivery" => "request-delivery-1",
        "X-GitHub-Event" => "push",
        "X-Hub-Signature-256" => signature(body)
      },
      env: { "lrail.git_provider" => provider }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq("status" => "accepted")
    expect(GitWebhookInbox.find_by!(delivery_id: "request-delivery-1")).to be_pending
  end

  it "rejects an invalid signature without persistence" do
    body = JSON.generate(secret: "must-not-leak")

    post "/webhooks/github",
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-GitHub-Delivery" => "request-delivery-invalid",
        "X-GitHub-Event" => "push",
        "X-Hub-Signature-256" => "sha256=invalid"
      },
      env: { "lrail.git_provider" => build_fake_git_provider }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("code")).to eq("invalid_signature")
    expect(GitWebhookInbox).not_to exist
  end
end
