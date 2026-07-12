require "rails_helper"

RSpec.describe "Temporal orchestrator bridge", type: :request do
  ORCHESTRATOR_SECRET = "temporal-orchestrator-test-secret-at-least-32-bytes".freeze

  around do |example|
    Dir.mktmpdir("orchestrator-auth") do |directory|
      path = Pathname(directory).join("secret")
      path.write(ORCHESTRATOR_SECRET)
      previous_secret = ENV["ORCHESTRATOR_SHARED_SECRET_FILE"]
      previous_mode = ENV["DEPLOYMENT_ORCHESTRATOR"]
      ENV["ORCHESTRATOR_SHARED_SECRET_FILE"] = path.to_s
      ENV["DEPLOYMENT_ORCHESTRATOR"] = "temporal"
      example.run
    ensure
      ENV["ORCHESTRATOR_SHARED_SECRET_FILE"] = previous_secret
      ENV["DEPLOYMENT_ORCHESTRATOR"] = previous_mode
    end
  end

  def signed_headers(method:, path:, body:, request_id: SecureRandom.uuid_v7, timestamp: Time.current.to_i)
    input = [ timestamp, request_id, method.upcase, path, body ].join("\n")
    signature = OpenSSL::HMAC.hexdigest("SHA256", ORCHESTRATOR_SECRET, input)
    {
      "Content-Type" => "application/json",
      "X-Lrail-Timestamp" => timestamp.to_s,
      "X-Lrail-Request-Id" => request_id,
      "X-Lrail-Signature" => "sha256=#{signature}"
    }
  end

  it "claims and finalizes one workflow command with replay safety" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "workflow-claim")
    event = OutboxEvent.find_by!(resource_id: deployment.id, event_type: "deployment.requested.v1")
    path = "/internal/v1/orchestrator/commands/claim"
    body = JSON.generate(event_types: [ "deployment.requested.v1" ])
    request_id = SecureRandom.uuid_v7
    headers = signed_headers(method: "POST", path:, body:, request_id:)

    post path, params: body, headers: headers
    first = response.parsed_body
    post path, params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(first)
    expect(first.dig("event", "event_id")).to eq(event.id)
    expect(event.reload).to have_attributes(status: "delivering", attempt_count: 1)

    finalize_path = "/internal/v1/orchestrator/commands/#{event.id}/finalize"
    finalize_body = JSON.generate(
      claim_token: first.fetch("claim_token"),
      outcome: "published"
    )
    finalize_headers = signed_headers(
      method: "POST",
      path: finalize_path,
      body: finalize_body
    )
    post finalize_path, params: finalize_body, headers: finalize_headers
    initial_result = response.parsed_body
    post finalize_path, params: finalize_body, headers: finalize_headers

    expect(response).to have_http_status(:ok)
    expect(initial_result).to eq("status" => "published", "replayed" => false)
    expect(response.parsed_body).to eq("status" => "published", "replayed" => true)
  end

  it "acknowledges stale operation reads without changing deployment state" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "workflow-operation")
    expected_version = deployment.lock_version
    path = "/internal/v1/orchestrator/operations"
    operation_id = SecureRandom.uuid_v7
    payload = {
      contract_version: 1,
      operation_id:,
      organization_id: deployment.organization_id,
      deployment_id: deployment.id,
      expected_version:,
      stage: "workflow_accepted"
    }
    body = JSON.generate(payload)

    post path, params: body, headers: signed_headers(method: "POST", path:, body:)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "operation_id" => operation_id,
      "accepted" => true,
      "stale" => false,
      "current_version" => expected_version,
      "deployment_status" => "created"
    )

    advance_deployment(deployment, to: :queued)
    post path,
      params: body,
      headers: signed_headers(method: "POST", path:, body:)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "accepted" => false,
      "stale" => true,
      "current_version" => deployment.reload.lock_version,
      "deployment_status" => "queued"
    )
    expect(deployment.status).to eq("queued")
  end

  it "rejects unsigned, disabled and malformed workflow requests" do
    path = "/internal/v1/orchestrator/commands/claim"
    body = JSON.generate(event_types: [ "deployment.requested.v1" ])

    post path, params: body, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)

    ENV["DEPLOYMENT_ORCHESTRATOR"] = "local"
    post path, params: body, headers: signed_headers(method: "POST", path:, body:)
    expect(response).to have_http_status(:conflict)

    ENV["DEPLOYMENT_ORCHESTRATOR"] = "temporal"
    operation_path = "/internal/v1/orchestrator/operations"
    malformed = JSON.generate(contract_version: 1, secret: "must-not-cross")
    post operation_path,
      params: malformed,
      headers: signed_headers(method: "POST", path: operation_path, body: malformed)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
