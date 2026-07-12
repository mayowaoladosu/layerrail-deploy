require "rails_helper"

RSpec.describe "Isolated build controller boundary", type: :request do
  SHARED_SECRET = "build-controller-test-secret-at-least-32-bytes".freeze
  ARTIFACT_DIGEST = "sha256:#{"b" * 64}".freeze

  around do |example|
    Dir.mktmpdir("build-controller-auth") do |directory|
      path = Pathname(directory).join("secret")
      path.write(SHARED_SECRET)
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
    signature = OpenSSL::HMAC.hexdigest("SHA256", SHARED_SECRET, input)
    {
      "Content-Type" => "application/json",
      "X-Lrail-Timestamp" => timestamp.to_s,
      "X-Lrail-Request-Id" => request_id,
      "X-Lrail-Signature" => "sha256=#{signature}"
    }
  end

  def connect_repository(context:, project:, service:)
    installation = GitInstallation.create!(
      organization: context.organization,
      provider: :github,
      provider_installation_id: "installation-#{service.id}",
      account_id: "account-#{service.id}",
      account_login: "layerrail",
      account_type: "organization",
      status: :active,
      permissions: { "contents" => "read" }
    )
    RepositoryConnection.create!(
      organization: context.organization,
      git_installation: installation,
      project:,
      service:,
      provider_repository_id: "repository-1",
      owner: "layerrail",
      name: "sample",
      full_name: "layerrail/sample",
      private: true,
      default_branch: "main",
      status: :active
    )
  end

  def workflow_input(deployment)
    event = OutboxEvent.find_by!(
      resource_id: deployment.id,
      event_type: "deployment.requested.v1"
    )
    {
      contract_version: 1,
      event_id: event.id,
      organization_id: deployment.organization_id,
      deployment_id: deployment.id,
      service_id: deployment.service_id,
      environment_id: deployment.environment_id,
      configuration_snapshot_id: deployment.configuration_snapshot_id,
      source_digest: "sha256:#{deployment.source_digest}",
      workload_type: deployment.build_settings_snapshot.fetch("workload_type"),
      expected_version: 0,
      operation_id: event.id
    }
  end

  def prepare(deployment)
    path = "/internal/v1/orchestrator/builds/prepare"
    body = JSON.generate(workflow_input(deployment))
    post path, params: body, headers: signed_headers(method: "POST", path:, body:)
    response
  end

  def completion_envelope(deployment:, build:, revision_id:, expected_version:, event_id: SecureRandom.uuid_v7, evidence: nil)
    {
      "event_id" => event_id,
      "event_type" => "deployment.build.completed.v1",
      "occurred_at" => Time.current.iso8601(6),
      "organization_id" => deployment.organization_id,
      "resource_id" => deployment.id,
      "correlation_id" => deployment.correlation_id,
      "idempotency_key" => "build:#{build.id}:completion",
      "producer" => "build-controller",
      "schema_version" => 1,
      "data" => {
        "contract_version" => 1,
        "operation_id" => workflow_input(deployment).fetch(:operation_id),
        "deployment_id" => deployment.id,
        "build_id" => build.id,
        "expected_version" => expected_version,
        "status" => "completed",
        "revision_id" => revision_id,
        "artifact_digest" => ARTIFACT_DIGEST,
        "evidence" => evidence || {
          "scan_status" => "passed",
          "plan_type" => "dockerfile_web",
          "artifact_kind" => "oci",
          "source_commit" => deployment.source_snapshot.fetch("commit_sha"),
          "log_tail" => [ "clone complete", "build complete", "scan passed" ]
        },
        "region" => "local",
        "cell" => "lrail-alpha"
      }
    }
  end

  def failure_envelope(deployment:, build:, expected_version:)
    {
      "event_id" => SecureRandom.uuid_v7,
      "event_type" => "deployment.build.completed.v1",
      "occurred_at" => Time.current.iso8601(6),
      "organization_id" => deployment.organization_id,
      "resource_id" => deployment.id,
      "correlation_id" => deployment.correlation_id,
      "idempotency_key" => "build:#{build.id}:failure",
      "producer" => "build-controller",
      "schema_version" => 1,
      "data" => {
        "contract_version" => 1,
        "operation_id" => workflow_input(deployment).fetch(:operation_id),
        "deployment_id" => deployment.id,
        "build_id" => build.id,
        "expected_version" => expected_version,
        "status" => "failed",
        "failure_code" => "unsupported_project",
        "evidence" => {
          "log_tail" => [ "2026-07-12T12:00:00Z unsupported project" ]
        },
        "error" => {
          "phase" => "detect",
          "code" => "unsupported_project",
          "message" => "No supported build plan was detected"
        }
      }
    }
  end

  def post_build_event(envelope)
    path = "/internal/v1/build-controller/events"
    body = JSON.generate(envelope)
    post path, params: body, headers: signed_headers(method: "POST", path:, body:)
  end

  it "prepares one idempotent Build and publishes a credential-free command" do
    context, project, _environment, service, deployment = create_deployment_domain(sequence: "build-boundary-prepare")
    connect_repository(context:, project:, service:)

    prepare(deployment)
    first = response.parsed_body
    prepare(deployment.reload)

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to eq(first)
    expect(first).to include(
      "accepted" => true,
      "stale" => false,
      "deployment_status" => "building"
    )
    build = Build.find(first.fetch("build_id"))
    command = OutboxEvent.find_by!(resource_id: build.id, event_type: "build.requested.v1")
    expect(build).to have_attributes(status: "running", attempt: 1)
    expect(build.evidence).to eq("planned_revision_id" => first.fetch("revision_id"))
    expect(command.data).to include(
      "command_type" => "build.start",
      "deployment_id" => deployment.id,
      "repository" => "lrail/#{context.organization.id}/#{service.id}",
      "expected_version" => deployment.reload.lock_version
    )
    expect(command.data.to_json).not_to match(/clone_url|password|secret|token/i)
    expect(Build.where(deployment:).count).to eq(1)
  end

  it "delivers expiring clone credentials only for the bound Build operation" do
    context, project, _environment, service, deployment = create_deployment_domain(sequence: "build-boundary-credentials")
    connect_repository(context:, project:, service:)
    prepare(deployment)
    prepared = response.parsed_body
    build = Build.find(prepared.fetch("build_id"))
    credentials = GitProviders::Types::CloneCredentials.new(
      clone_url: "https://git.example.test/layerrail/sample.git",
      username: "x-access-token",
      secret: "ephemeral-clone-secret",
      expires_at: 10.minutes.from_now
    )
    session = instance_double(GitProviders::Session)
    provider = instance_double(GitProviders::Adapter)
    allow(session).to receive(:clone_credentials).and_return(GitProviders::Result.success(credentials))
    allow(provider).to receive(:open_session).and_return(GitProviders::Result.success(session))
    allow(GitProviders::Factory).to receive(:github).and_return(provider)
    operation_id = workflow_input(deployment).fetch(:operation_id)
    path = "/internal/v1/build-controller/builds/#{build.id}/credentials"

    get "#{path}?operation_id=#{operation_id}", headers: signed_headers(method: "GET", path:, body: "")

    expect(response).to have_http_status(:ok), response.body
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    expect(response.parsed_body).to include(
      "build_id" => build.id,
      "clone_url" => "https://git.example.test/layerrail/sample.git",
      "username" => "x-access-token",
      "secret" => "ephemeral-clone-secret"
    )
    expect(build.reload.evidence.to_json).not_to include("ephemeral-clone-secret")

    foreign_context, foreign_project, _foreign_environment, foreign_service, foreign_deployment =
      create_deployment_domain(sequence: "build-boundary-credentials-foreign")
    connect_repository(context: foreign_context, project: foreign_project, service: foreign_service)
    prepare(foreign_deployment)
    foreign_build = Build.find(response.parsed_body.fetch("build_id"))
    foreign_path = "/internal/v1/build-controller/builds/#{foreign_build.id}/credentials"
    get "#{foreign_path}?operation_id=#{operation_id}", headers: signed_headers(method: "GET", path: foreign_path, body: "")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).not_to include("ephemeral-clone-secret")
  end

  it "persists a scanned completion once and publishes its sanitized workflow signal" do
    context, project, _environment, service, deployment = create_deployment_domain(sequence: "build-boundary-complete")
    connect_repository(context:, project:, service:)
    prepare(deployment)
    prepared = response.parsed_body
    build = Build.find(prepared.fetch("build_id"))
    envelope = completion_envelope(
      deployment:,
      build:,
      revision_id: prepared.fetch("revision_id"),
      expected_version: prepared.fetch("current_version")
    )

    post_build_event(envelope)
    first = response.parsed_body
    post_build_event(envelope)

    expect(response).to have_http_status(:ok), response.body
    expect(first.fetch("replayed")).to be(false)
    expect(response.parsed_body.fetch("replayed")).to be(true)
    expect(build.reload).to have_attributes(status: "succeeded", artifact_digest: ARTIFACT_DIGEST)
    expect(build.revision).to have_attributes(
      id: prepared.fetch("revision_id"),
      status: "candidate",
      artifact_digest: ARTIFACT_DIGEST
    )
    expect(deployment.reload.status).to eq("scanning")
    signal = OutboxEvent.find_by!(
      resource_id: deployment.id,
      event_type: "deployment.build.completed.v1"
    )
    expect(signal.data).to include(
      "status" => "completed",
      "build_id" => build.id,
      "artifact_digest" => ARTIFACT_DIGEST,
      "expected_version" => deployment.lock_version
    )
    expect(signal.data.to_json).not_to match(/log_tail|provenance|sbom|secret/i)

    prepare(deployment.reload)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      "build_id" => build.id,
      "revision_id" => prepared.fetch("revision_id"),
      "current_version" => prepared.fetch("current_version"),
      "deployment_status" => "building"
    )
  end

  it "rejects failed scan evidence and records bounded terminal build failures" do
    context, project, _environment, service, deployment = create_deployment_domain(sequence: "build-boundary-policy")
    connect_repository(context:, project:, service:)
    prepare(deployment)
    prepared = response.parsed_body
    build = Build.find(prepared.fetch("build_id"))
    rejected = completion_envelope(
      deployment:,
      build:,
      revision_id: prepared.fetch("revision_id"),
      expected_version: prepared.fetch("current_version"),
      evidence: {
        "scan_status" => "failed",
        "plan_type" => "dockerfile_web",
        "artifact_kind" => "oci"
      }
    )

    post_build_event(rejected)

    expect(response).to have_http_status(:unprocessable_content)
    expect(build.reload.status).to eq("running")
    expect(build.revision).to be_nil

    failure = failure_envelope(
      deployment:,
      build:,
      expected_version: prepared.fetch("current_version")
    )
    post_build_event(failure)

    expect(response).to have_http_status(:ok), response.body
    expect(build.reload.status).to eq("failed")
    expect(build.evidence.fetch("log_tail")).to include(a_string_matching("unsupported project"))
    expect(deployment.reload).to have_attributes(status: "failed", conclusion: "failed")
    expect(build.revision).to be_nil
  end

  it "turns a workflow cancellation into one build command and one terminal Build" do
    context, project, _environment, service, deployment = create_deployment_domain(sequence: "build-boundary-cancel")
    connect_repository(context:, project:, service:)
    prepare(deployment)
    prepared = response.parsed_body
    build = Build.find(prepared.fetch("build_id"))
    canceled = Deployments::Cancel.call(
      context:,
      deployment: deployment.reload,
      expected_lock_version: deployment.lock_version
    ).deployment
    cancellation_event = OutboxEvent.find_by!(
      resource_id: deployment.id,
      event_type: "deployment.cancellation.requested.v1"
    )
    cancel_path = "/internal/v1/orchestrator/builds/cancel"
    cancel_body = JSON.generate(
      contract_version: 1,
      event_id: cancellation_event.id,
      operation_id: cancellation_event.id,
      organization_id: deployment.organization_id,
      deployment_id: deployment.id,
      expected_version: canceled.lock_version,
      message_type: "deployment.cancel",
      transition_id: cancellation_event.data.fetch("transition_id")
    )

    post cancel_path,
      params: cancel_body,
      headers: signed_headers(method: "POST", path: cancel_path, body: cancel_body)

    expect(response).to have_http_status(:ok), response.body
    command = OutboxEvent.find_by!(resource_id: build.id, event_type: "build.cancellation.requested.v1")
    callback_path = "/internal/v1/build-controller/cancellations"
    callback_value = command.data.slice(
      "contract_version", "operation_id", "organization_id", "deployment_id",
      "build_id", "expected_version"
    ).merge(
      "evidence" => {
        "log_tail" => [ "2026-07-12T12:00:00Z cancellation requested" ]
      }
    )
    callback_body = JSON.generate(callback_value)
    post callback_path,
      params: callback_body,
      headers: signed_headers(method: "POST", path: callback_path, body: callback_body)
    first = response.parsed_body
    post callback_path,
      params: callback_body,
      headers: signed_headers(method: "POST", path: callback_path, body: callback_body)

    expect(response).to have_http_status(:ok), response.body
    expect(first.fetch("replayed")).to be(false)
    expect(response.parsed_body.fetch("replayed")).to be(true)
    expect(build.reload.status).to eq("canceled")
    expect(build.evidence.fetch("log_tail")).to include(a_string_matching("cancellation requested"))
    expect(deployment.reload).to have_attributes(status: "canceled", conclusion: "canceled")
    expect(build.revision).to be_nil
  end

  it "rejects unsigned and disabled build-controller requests" do
    path = "/internal/v1/build-controller/commands/claim"
    body = JSON.generate(event_types: [ "build.requested.v1" ])

    post path, params: body, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)

    ENV["DEPLOYMENT_ORCHESTRATOR"] = "local"
    post path, params: body, headers: signed_headers(method: "POST", path:, body:)
    expect(response).to have_http_status(:conflict)
  end
end
