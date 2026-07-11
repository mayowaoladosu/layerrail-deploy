require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "POST /v1/projects", type: :request do
  def api_schema(name)
    contract_path = Pathname(
      ENV.fetch("LRAIL_CONTRACTS_DIR", Rails.root.join("../../contracts"))
    ).join("openapi/v1/openapi.yaml")
    @api_document ||= JSONSchemer.openapi(YAML.safe_load_file(contract_path, aliases: true))

    @api_document.schema(name)
  end

  def create_organization(email: "api-project-owner@example.com")
    owner = User.create!(email:, name: "API Owner")
    organization = Organizations::Create.call(principal: owner, name: "API Organization").organization

    [ owner, organization ]
  end

  def post_project(principal:, organization:, key:, name: "Customer Portal", slug: "customer-portal")
    headers = {}
    headers["Idempotency-Key"] = key if key

    post "/v1/projects",
      params: {
        organization_id: organization.id,
        name:,
        slug:
      },
      headers:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  it "creates an organization-owned project for an authenticated owner" do
    owner, organization = create_organization

    post_project(principal: owner, organization:, key: "create-customer-portal")

    expect(response).to have_http_status(:created)
    expect(response.media_type).to eq("application/json")
    expect(response.headers.fetch("X-Correlation-Id")).to match(/\A[0-9a-f-]{36}\z/)
    expect(response.parsed_body).to include(
      "organization_id" => organization.id,
      "name" => "Customer Portal",
      "slug" => "customer-portal"
    )
    expect(api_schema("Project")).to be_valid(response.parsed_body)
    expect(Project.find(response.parsed_body.fetch("id")).environments.count).to eq(2)
  end

  it "requires an idempotency key before creating state" do
    owner, organization = create_organization(email: "missing-key-owner@example.com")

    expect do
      post_project(principal: owner, organization:, key: nil)
    end.not_to change(Project, :count)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_required")
    expect(response.parsed_body.fetch("correlation_id")).to eq(response.headers.fetch("X-Correlation-Id"))
    expect(api_schema("Error")).to be_valid(response.parsed_body)
  end

  it "replays one logical result for the same key and request" do
    owner, organization = create_organization(email: "replay-owner@example.com")

    expect do
      post_project(principal: owner, organization:, key: "replay-project")
      @first_response = response.parsed_body
      post_project(principal: owner, organization:, key: "replay-project")
    end.to change(Project, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to eq(@first_response)
    expect(response.headers.fetch("Idempotency-Replayed")).to eq("true")
  end

  it "rejects reuse of a key for a different request" do
    owner, organization = create_organization(email: "conflict-owner@example.com")
    post_project(principal: owner, organization:, key: "conflicting-project")

    expect do
      post_project(
        principal: owner,
        organization:,
        key: "conflicting-project",
        name: "Different",
        slug: "different"
      )
    end.not_to change(Project, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_conflict")
  end

  it "fails closed without an authenticated principal" do
    _owner, organization = create_organization(email: "unauthenticated-owner@example.com")

    post_project(principal: nil, organization:, key: "unauthenticated-project")

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("code")).to eq("unauthenticated")
  end

  it "forbids a member from creating a project" do
    owner, organization = create_organization(email: "authorization-owner@example.com")
    member = User.create!(email: "api-project-member@example.com", name: "Member")
    organization.memberships.create!(user: member, role: :member)

    post_project(principal: member, organization:, key: "forbidden-project")

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("code")).to eq("forbidden")
    expect(owner).to be_persisted
  end

  it "forbids a principal from selecting another organization" do
    owner, _organization = create_organization(email: "selected-owner@example.com")
    _foreign_owner, foreign_organization = create_organization(email: "foreign-selected-owner@example.com")

    post_project(principal: owner, organization: foreign_organization, key: "cross-organization-project")

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.fetch("code")).to eq("organization_not_found")
    expect(Project.where(organization: foreign_organization)).not_to exist
    expect(IdempotencyRecord.where(organization: foreign_organization)).not_to exist
  end

  it "does not consume the key when validation rolls back" do
    owner, organization = create_organization(email: "validation-retry-owner@example.com")

    post_project(
      principal: owner,
      organization:,
      key: "validation-retry",
      name: " ",
      slug: " "
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(IdempotencyRecord.where(organization:, key: "validation-retry")).not_to exist

    post_project(principal: owner, organization:, key: "validation-retry")

    expect(response).to have_http_status(:created)
  end

  it "rejects an invalid idempotency key" do
    owner, organization = create_organization(email: "invalid-key-owner@example.com")

    post_project(principal: owner, organization:, key: "x" * 256)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("code")).to eq("idempotency_key_invalid")
  end
end
