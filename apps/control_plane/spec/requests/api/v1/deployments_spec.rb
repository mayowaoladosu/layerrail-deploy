require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "Deployment API", type: :request do
  def api_schema(name)
    contract_path = Pathname(
      ENV.fetch("LRAIL_CONTRACTS_DIR", Rails.root.join("../../contracts"))
    ).join("openapi/v1/openapi.yaml")
    @api_document ||= JSONSchemer.openapi(YAML.safe_load_file(contract_path, aliases: true))

    @api_document.schema(name)
  end

  def create_domain(sequence:)
    owner = User.create!(email: "deployment-api-#{sequence}@example.com", name: "Deployment API")
    organization = Organizations::Create.call(principal: owner, name: "Deployment API #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(
      context:,
      name: "Deployment Project #{sequence}",
      slug: "deployment-project-#{sequence}"
    ).project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-#{sequence}"
    ).service

    [ owner, organization, context, project, service ]
  end

  def source(sequence = "a")
    {
      type: "git",
      reference: "main",
      repository_id: "repository-1",
      commit_sha: sequence * 40,
      root_directory: "apps/api"
    }
  end

  def post_deployment(principal:, service:, key:, payload: {})
    headers = {}
    headers["Idempotency-Key"] = key if key

    post "/v1/services/#{service.id}/deployments",
      params: { source: source }.merge(payload),
      headers:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  def get_deployment(principal:, deployment:)
    get "/v1/deployments/#{deployment.id}",
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  def create_deployment(context:, service:, key:)
    Deployments::Create.call(
      context:,
      service:,
      environment: service.project.environments.find_by!(kind: :production),
      source: source.transform_keys(&:to_s),
      idempotency_key: key,
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
  end

  def post_cancel(principal:, deployment:, key:, reason: nil)
    headers = {}
    headers["Idempotency-Key"] = key if key
    params = reason.nil? ? {} : { reason: }

    post "/v1/deployments/#{deployment.id}/cancel",
      params:,
      headers:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  it "accepts one immutable Deployment and returns a schema-valid representation" do
    owner, organization, _context, project, service = create_domain(sequence: "create")
    environment = project.environments.find_by!(kind: :production)

    expect do
      post_deployment(
        principal: owner,
        service:,
        key: "create-deployment",
        payload: { environment_id: environment.id }
      )
    end.to change(Deployment, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(api_schema("CreateDeploymentRequest")).to be_valid(
      "source" => source.transform_keys(&:to_s),
      "environment_id" => environment.id
    )
    expect(api_schema("Deployment")).to be_valid(response.parsed_body)
    expect(response.parsed_body).to include(
      "organization_id" => organization.id,
      "service_id" => service.id,
      "environment_id" => environment.id,
      "revision_id" => nil,
      "status" => "created",
      "source" => include(
        "commit_sha" => "a" * 40,
        "root_directory" => "apps/api"
      ),
      "preview_url" => match(%r{\Ahttp://d-[0-9a-f-]+\.localhost\z})
    )
    deployment = Deployment.find(response.parsed_body.fetch("id"))
    expect(deployment.environment).to eq(environment)
    expect(OutboxEvent.where(resource_id: deployment.id, event_type: "deployment.requested.v1").count).to eq(1)
  end

  it "replays one result after workflow progress and rejects changed key reuse" do
    owner, _organization, context, _project, service = create_domain(sequence: "replay")
    post_deployment(principal: owner, service:, key: "deployment-replay")
    first_body = response.parsed_body
    deployment = Deployment.find(first_body.fetch("id"))
    advance_deployment(deployment, to: :queued, actor: context.principal)

    post_deployment(principal: owner, service:, key: "deployment-replay")

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(first_body)
    expect(response.headers.fetch("Idempotency-Replayed")).to eq("true")
    expect(Deployment.count).to eq(1)

    post_deployment(
      principal: owner,
      service:,
      key: "deployment-replay",
      payload: { source: source("b") }
    )

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_conflict")
  end

  it "defaults to production and validates source and idempotency input" do
    owner, _organization, _context, project, service = create_domain(sequence: "validation")

    post_deployment(principal: owner, service:, key: nil)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_required")

    post_deployment(
      principal: owner,
      service:,
      key: "invalid-source",
      payload: { source: source.merge(commit_sha: "invalid") }
    )
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("code")).to eq("validation_failed")
    expect(api_schema("CreateDeploymentRequest")).not_to be_valid(
      "source" => {
        "type" => "git",
        "reference" => "main",
        "repository_id" => "repository-1"
      }
    )

    post_deployment(
      principal: owner,
      service:,
      key: "unknown-source-field",
      payload: { source: source.merge(token: "must-not-be-accepted") }
    )
    expect(response).to have_http_status(:unprocessable_content)
    expect(Deployment.where(idempotency_key: "unknown-source-field")).not_to exist

    post_deployment(
      principal: owner,
      service:,
      key: "unsafe-root-directory",
      payload: { source: source.merge(root_directory: "../secrets") }
    )
    expect(response).to have_http_status(:unprocessable_content)
    expect(Deployment.where(idempotency_key: "unsafe-root-directory")).not_to exist

    post_deployment(principal: owner, service:, key: "default-production")
    expect(response).to have_http_status(:accepted)
    expect(Deployment.find(response.parsed_body.fetch("id")).environment)
      .to eq(project.environments.find_by!(kind: :production))
  end

  it "fails closed for unauthenticated, member, cross-tenant and cross-project requests" do
    owner, organization, context, _project, service = create_domain(sequence: "authorization")
    member = User.create!(email: "deployment-api-member@example.com", name: "Member")
    organization.memberships.create!(user: member, role: :member)
    _foreign_owner, _foreign_organization, _foreign_context, _foreign_project, foreign_service =
      create_domain(sequence: "foreign")
    other_project = Projects::Create.call(
      context:,
      name: "Other Project",
      slug: "other-project"
    ).project

    post_deployment(principal: nil, service:, key: "unauthenticated")
    expect(response).to have_http_status(:unauthorized)

    post_deployment(principal: member, service:, key: "member-forbidden")
    expect(response).to have_http_status(:forbidden)

    post_deployment(principal: owner, service: foreign_service, key: "cross-tenant")
    expect(response).to have_http_status(:not_found)

    post_deployment(
      principal: owner,
      service:,
      key: "cross-project-environment",
      payload: { environment_id: other_project.environments.find_by!(kind: :production).id }
    )
    expect(response).to have_http_status(:not_found)
  end

  it "shows a Deployment to organization members and hides foreign Deployments" do
    owner, organization, context, _project, service = create_domain(sequence: "show")
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment: service.project.environments.find_by!(kind: :production),
      source: source.transform_keys(&:to_s),
      idempotency_key: "show-deployment",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
    member = User.create!(email: "deployment-api-viewer@example.com", name: "Viewer")
    organization.memberships.create!(user: member, role: :member)
    foreign_owner, = create_domain(sequence: "show-foreign")

    get_deployment(principal: member, deployment:)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("id")).to eq(deployment.id)
    expect(api_schema("Deployment")).to be_valid(response.parsed_body)

    get_deployment(principal: foreign_owner, deployment:)
    expect(response).to have_http_status(:not_found)
  end

  it "accepts and replays one cancellation operation" do
    owner, organization, context, _project, service = create_domain(sequence: "cancel")
    deployment = create_deployment(context:, service:, key: "cancel-target")

    post_cancel(principal: owner, deployment:, key: "cancel-operation", reason: "No longer needed")
    first_body = response.parsed_body

    expect(response).to have_http_status(:accepted)
    expect(api_schema("Operation")).to be_valid(first_body)
    expect(first_body).to include(
      "organization_id" => organization.id,
      "resource_id" => deployment.id,
      "status" => "pending",
      "correlation_id" => deployment.correlation_id
    )
    expect(deployment.reload.status).to eq("canceling")
    expect(OutboxEvent.find(first_body.fetch("id")).data).to include(
      "to_status" => "canceling",
      "cause" => "cancellation_requested"
    )

    post_cancel(principal: owner, deployment:, key: "cancel-operation", reason: "No longer needed")
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(first_body)
    expect(response.headers.fetch("Idempotency-Replayed")).to eq("true")

    post_cancel(principal: owner, deployment:, key: "cancel-operation", reason: "Changed reason")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_conflict")
  end

  it "rejects invalid, unauthorized and foreign cancellation requests" do
    owner, organization, context, _project, service = create_domain(sequence: "cancel-errors")
    deployment = create_deployment(context:, service:, key: "cancel-errors-target")
    member = User.create!(email: "deployment-cancel-member@example.com", name: "Member")
    organization.memberships.create!(user: member, role: :member)
    foreign_owner, = create_domain(sequence: "cancel-foreign")

    post_cancel(principal: owner, deployment:, key: nil)
    expect(response).to have_http_status(:bad_request)

    post_cancel(principal: owner, deployment:, key: "cancel-long-reason", reason: "x" * 501)
    expect(response).to have_http_status(:unprocessable_content)

    post_cancel(principal: member, deployment:, key: "cancel-member")
    expect(response).to have_http_status(:forbidden)

    post_cancel(principal: foreign_owner, deployment:, key: "cancel-foreign")
    expect(response).to have_http_status(:not_found)

    deployment = Deployments::Transition.call(
      deployment: deployment.reload,
      to: :failed,
      actor: nil,
      cause: "failed_before_cancel",
      expected_lock_version: deployment.lock_version,
      error: { "phase" => "test", "code" => "failed", "message" => "Failed" }
    ).deployment
    post_cancel(principal: owner, deployment:, key: "cancel-terminal")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("invalid_transition")
  end

  it "rejects cancellation while the Deployment is serving an Alias" do
    owner, _organization, context, project, service = create_domain(sequence: "cancel-serving")
    environment = project.environments.find_by!(kind: :production)
    deployment = create_deployment(context:, service:, key: "cancel-serving-target")
    deployment = advance_deployment(deployment, to: :queued, actor: owner)
    deployment = advance_deployment(deployment, to: :preparing, actor: owner)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "cancel-serving-build",
      expected_lock_version: deployment.lock_version
    ).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"e" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    revision = Revisions::MarkReady.call(
      revision:,
      readiness: { "status" => "passed" }
    ).revision
    Aliases::Promote.call(
      context:,
      revision:,
      alias_type: :environment,
      name: environment.slug
    )

    post_cancel(principal: owner, deployment:, key: "cancel-serving-operation")

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("deployment_in_use")
    expect(deployment.reload.status).to eq("promoted")
  end
end
