require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "Environment operation API", type: :request do
  def api_schema(name)
    contract_path = Pathname(
      ENV.fetch("LRAIL_CONTRACTS_DIR", Rails.root.join("../../contracts"))
    ).join("openapi/v1/openapi.yaml")
    @api_document ||= JSONSchemer.openapi(YAML.safe_load_file(contract_path, aliases: true))

    @api_document.schema(name)
  end

  def ready_revision(context:, deployment:, sequence:)
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "api-build-#{sequence}",
      expected_lock_version: deployment.lock_version
    ).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{Digest::SHA256.hexdigest(sequence)}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    Revisions::MarkReady.call(revision:, readiness: { "status" => "passed" }).revision
  end

  def next_deployment(context:, service:, environment:, sequence:)
    Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "git",
        "reference" => "main",
        "repository_id" => "repository-1",
        "commit_sha" => Digest::SHA1.hexdigest(sequence)
      },
      idempotency_key: "api-deployment-#{sequence}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
  end

  def post_promotion(principal:, environment:, revision_id:, key:)
    headers = {}
    headers["Idempotency-Key"] = key if key

    post "/v1/environments/#{environment.id}/promotions",
      params: { revision_id: },
      headers:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  def post_rollback(principal:, environment:, revision_id:, key:)
    headers = {}
    headers["Idempotency-Key"] = key if key

    post "/v1/environments/#{environment.id}/rollbacks",
      params: { revision_id: },
      headers:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  it "promotes a ready Revision and replays one schema-valid routing operation" do
    context, _project, environment, service, deployment = create_deployment_domain(sequence: "api-promote")
    revision = ready_revision(context:, deployment:, sequence: "api-promote")

    post_promotion(
      principal: context.principal,
      environment:,
      revision_id: revision.id,
      key: "promote-ready"
    )
    first_body = response.parsed_body

    expect(response).to have_http_status(:accepted)
    expect(api_schema("Operation")).to be_valid(first_body)
    expect(first_body).to include(
      "organization_id" => context.organization.id,
      "status" => "pending",
      "correlation_id" => revision.deployment.correlation_id
    )
    alias_record = Alias.find(first_body.fetch("resource_id"))
    expect(alias_record).to have_attributes(
      environment:,
      service:,
      current_revision: revision,
      previous_revision: nil
    )
    expect(OutboxEvent.find(first_body.fetch("id")).event_type).to eq("alias.routing.requested.v1")

    post_promotion(
      principal: context.principal,
      environment:,
      revision_id: revision.id,
      key: "promote-ready"
    )
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(first_body)
    expect(response.headers.fetch("Idempotency-Replayed")).to eq("true")
  end

  it "rejects missing, candidate, member and foreign promotion selections" do
    context, _project, environment, service, deployment = create_deployment_domain(sequence: "api-promote-errors")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "api-promote-candidate-build",
      expected_lock_version: deployment.lock_version
    ).build
    candidate = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"d" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    member = User.create!(email: "environment-api-member@example.com", name: "Member")
    context.organization.memberships.create!(user: member, role: :member)
    foreign_context, _foreign_project, foreign_environment, _foreign_service, foreign_deployment =
      create_deployment_domain(sequence: "api-promote-foreign")
    foreign_revision = ready_revision(
      context: foreign_context,
      deployment: foreign_deployment,
      sequence: "api-promote-foreign"
    )

    post_promotion(principal: context.principal, environment:, revision_id: nil, key: "promote-missing")
    expect(response).to have_http_status(:unprocessable_content)

    post_promotion(
      principal: context.principal,
      environment:,
      revision_id: candidate.id,
      key: "promote-candidate"
    )
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("revision_not_ready")

    post_promotion(principal: member, environment:, revision_id: candidate.id, key: "promote-member")
    expect(response).to have_http_status(:forbidden)

    post_promotion(
      principal: context.principal,
      environment: foreign_environment,
      revision_id: foreign_revision.id,
      key: "promote-foreign"
    )
    expect(response).to have_http_status(:not_found)
    expect(service).to be_persisted
  end

  it "rolls back to the explicitly selected previous Revision without rebuilding" do
    context, _project, environment, service, first_deployment = create_deployment_domain(sequence: "api-rollback")
    first_revision = ready_revision(context:, deployment: first_deployment, sequence: "api-rollback-first")
    Aliases::Promote.call(
      context:,
      revision: first_revision,
      alias_type: :environment,
      name: environment.slug
    )
    second_revision = ready_revision(
      context:,
      deployment: next_deployment(
        context:,
        service:,
        environment:,
        sequence: "api-rollback-second"
      ),
      sequence: "api-rollback-second"
    )
    alias_record = Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    ).alias_record
    build_count = Build.count

    post_rollback(
      principal: context.principal,
      environment:,
      revision_id: first_revision.id,
      key: "rollback-previous"
    )
    first_body = response.parsed_body

    expect(response).to have_http_status(:accepted)
    expect(api_schema("Operation")).to be_valid(first_body)
    expect(alias_record.reload).to have_attributes(
      current_revision: first_revision,
      previous_revision: second_revision
    )
    expect(Build.count).to eq(build_count)

    post_rollback(
      principal: context.principal,
      environment:,
      revision_id: first_revision.id,
      key: "rollback-previous"
    )
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(first_body)

    post_rollback(
      principal: context.principal,
      environment:,
      revision_id: second_revision.id,
      key: "rollback-previous"
    )
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_conflict")

    post_rollback(
      principal: context.principal,
      environment:,
      revision_id: first_revision.id,
      key: "rollback-not-previous"
    )
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("revision_mismatch")
  end

  it "rejects rollback when no previous Revision exists" do
    context, _project, environment, _service, deployment = create_deployment_domain(sequence: "api-rollback-errors")
    revision = ready_revision(context:, deployment:, sequence: "api-rollback-errors")
    Aliases::Promote.call(
      context:,
      revision:,
      alias_type: :environment,
      name: environment.slug
    )

    post_rollback(
      principal: context.principal,
      environment:,
      revision_id: revision.id,
      key: "rollback-without-previous"
    )
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("previous_revision_missing")
  end
end
