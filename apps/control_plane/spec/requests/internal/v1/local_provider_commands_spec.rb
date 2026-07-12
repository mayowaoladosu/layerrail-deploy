require "rails_helper"

RSpec.describe "Local provider command transport", type: :request do
  COMMAND_SECRET = "local-provider-test-secret-with-at-least-32-bytes".freeze

  around do |example|
    Dir.mktmpdir("provider-auth") do |directory|
      path = Pathname(directory).join("secret")
      path.write(COMMAND_SECRET)
      previous = ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"]
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = path.to_s
      example.run
    ensure
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = previous
    end
  end

  def create_event
    owner = User.create!(email: "provider-command@example.com", name: "Provider Command")
    organization = Organizations::Create.call(principal: owner, name: "Provider Command").organization
    OutboxEvents::Publish.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.requested.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "provider-command",
      producer: "control-plane",
      data: { "expected_version" => 0 }
    ).event
  end

  def signed_headers(method:, path:, body:, request_id: SecureRandom.uuid_v7, timestamp: Time.current.to_i)
    input = [ timestamp, request_id, method.upcase, path, body ].join("\n")
    signature = OpenSSL::HMAC.hexdigest("SHA256", COMMAND_SECRET, input)
    {
      "Content-Type" => "application/json",
      "X-Lrail-Timestamp" => timestamp.to_s,
      "X-Lrail-Request-Id" => request_id,
      "X-Lrail-Signature" => "sha256=#{signature}"
    }
  end

  it "claims and replays one signed provider command" do
    event = create_event
    path = "/internal/v1/local-provider/commands/claim"
    body = JSON.generate(event_types: [ "deployment.requested.v1", "alias.routing.requested.v1" ])
    request_id = SecureRandom.uuid_v7
    headers = signed_headers(method: :post, path:, body:, request_id:)

    post path, params: body, headers: headers
    first = response.parsed_body
    post path, params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(first)
    expect(first.fetch("event").fetch("event_id")).to eq(event.id)
    expect(first.fetch("claim_token")).to match(/\A[0-9a-f-]{36}\z/)
    expect(first.fetch("lease_expires_at")).to be_present
    expect(event.reload).to have_attributes(status: "delivering", attempt_count: 1, claim_request_id: request_id)
  end

  it "returns no content when no supported command is eligible" do
    path = "/internal/v1/local-provider/commands/claim"
    body = JSON.generate(event_types: [ "deployment.requested.v1" ])

    post path,
      params: body,
      headers: signed_headers(method: :post, path:, body:)

    expect(response).to have_http_status(:no_content)
  end

  it "finalizes a claimed command and replays completion" do
    event = create_event
    claim_path = "/internal/v1/local-provider/commands/claim"
    claim_body = JSON.generate(event_types: [ "deployment.requested.v1" ])
    post claim_path,
      params: claim_body,
      headers: signed_headers(method: :post, path: claim_path, body: claim_body)
    claim = response.parsed_body
    path = "/internal/v1/local-provider/commands/#{event.id}/finalize"
    body = JSON.generate(claim_token: claim.fetch("claim_token"), outcome: "published")
    headers = signed_headers(method: :post, path:, body:)

    post path, params: body, headers: headers
    first = response.parsed_body
    post path, params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(first).to eq("status" => "published", "replayed" => false)
    expect(response.parsed_body).to eq("status" => "published", "replayed" => true)
    expect(event.reload.status).to eq("published")
  end

  it "rejects invalid, expired and stale signed requests without changing commands" do
    event = create_event
    path = "/internal/v1/local-provider/commands/claim"
    body = JSON.generate(event_types: [ "deployment.requested.v1" ])

    post path, params: body, headers: signed_headers(method: :post, path:, body:).merge("X-Lrail-Signature" => "sha256=invalid")
    expect(response).to have_http_status(:unauthorized)

    post path,
      params: body,
      headers: signed_headers(method: :post, path:, body:, timestamp: 5.minutes.ago.to_i)
    expect(response).to have_http_status(:unauthorized)
    expect(event.reload.status).to eq("pending")
  end
end
