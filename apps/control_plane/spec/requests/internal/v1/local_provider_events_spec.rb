require "rails_helper"

RSpec.describe "Local provider callback transport", type: :request do
  CALLBACK_SECRET = "local-provider-callback-secret-at-least-32-bytes".freeze

  around do |example|
    Dir.mktmpdir("provider-callback-auth") do |directory|
      path = Pathname(directory).join("secret")
      path.write(CALLBACK_SECRET)
      previous = ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"]
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = path.to_s
      example.run
    ensure
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = previous
    end
  end

  def setup_deployment
    context, _project, environment, service, _deployment = create_deployment_domain(sequence: "callback-request")
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "oci",
        "reference" => "lrail-local-sample:dev",
        "digest" => "sha256:#{"a" * 64}"
      },
      idempotency_key: "callback-request-deployment",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
    command = OutboxEvent.find_by!(resource_id: deployment.id, event_type: "deployment.requested.v1")
    [ deployment, command ]
  end

  def callback(deployment:, command:)
    {
      "event_id" => SecureRandom.uuid_v7,
      "event_type" => "deployment.runtime.ready.v1",
      "occurred_at" => Time.current.iso8601(6),
      "organization_id" => deployment.organization_id,
      "resource_id" => deployment.id,
      "correlation_id" => deployment.correlation_id,
      "idempotency_key" => "local-provider:#{command.id}:ready",
      "producer" => "local-provider",
      "schema_version" => 1,
      "data" => {
        "deployment_id" => deployment.id,
        "operation_id" => command.id,
        "expected_version" => 0,
        "artifact_digest" => deployment.source_snapshot.fetch("digest"),
        "region" => "local",
        "cell" => "docker-desktop",
        "readiness" => { "status" => "passed", "checked_at" => Time.current.iso8601(6) }
      }
    }
  end

  def signed_headers(path:, body:, request_id: SecureRandom.uuid_v7, timestamp: Time.current.to_i)
    input = [ timestamp, request_id, "POST", path, body ].join("\n")
    signature = OpenSSL::HMAC.hexdigest("SHA256", CALLBACK_SECRET, input)
    {
      "Content-Type" => "application/json",
      "X-Lrail-Timestamp" => timestamp.to_s,
      "X-Lrail-Request-Id" => request_id,
      "X-Lrail-Signature" => "sha256=#{signature}"
    }
  end

  it "accepts and replays one signed canonical callback" do
    deployment, command = setup_deployment
    event = callback(deployment:, command:)
    path = "/internal/v1/local-provider/events"
    body = JSON.generate(event)
    headers = signed_headers(path:, body:)

    post path, params: body, headers: headers
    first = response.parsed_body
    post path, params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(first.fetch("replayed")).to be(false)
    expect(response.parsed_body).to eq(first.merge("replayed" => true))
    expect(first.fetch("result")).to include(
      "deployment_id" => deployment.id,
      "revision_id" => be_present,
      "ignored" => false
    )
    expect(deployment.reload.status).to eq("ready")
  end

  it "rejects unsigned or invalid callbacks before domain state changes" do
    deployment, command = setup_deployment
    event = callback(deployment:, command:)
    path = "/internal/v1/local-provider/events"
    body = JSON.generate(event)

    post path, params: body, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)

    event["data"]["artifact_digest"] = "sha256:#{"f" * 64}"
    body = JSON.generate(event)
    post path, params: body, headers: signed_headers(path:, body:)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("invalid_event")
    expect(deployment.reload.status).to eq("created")
  end
end
