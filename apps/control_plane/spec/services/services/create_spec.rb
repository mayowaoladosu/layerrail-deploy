require "rails_helper"

RSpec.describe Services::Create do
  it "creates an organization-scoped deployable workload" do
    owner = User.create!(email: "service-owner@example.com", name: "Service Owner")
    organization = Organizations::Create.call(principal: owner, name: "Services").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Platform", slug: "platform").project

    result = described_class.call(
      context:,
      project:,
      name: "  Public API  ",
      workload_type: :web,
      source_type: :git,
      source_reference: "  github:layerrail/api  ",
      runtime_policy: { "readiness_path" => "/health" }
    )

    expect(result.service).to have_attributes(
      project:,
      organization:,
      organization_id: organization.id,
      name: "Public API",
      workload_type: "web",
      source_type: "git",
      source_reference: "github:layerrail/api",
      runtime_policy: { "readiness_path" => "/health" },
      lifecycle_state: "active"
    )
    expect(result.service.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  it "rejects a member before creating a service" do
    owner = User.create!(email: "service-member-owner@example.com", name: "Owner")
    member = User.create!(email: "service-member@example.com", name: "Member")
    organization = Organizations::Create.call(principal: owner, name: "Member Services").organization
    organization.memberships.create!(user: member, role: :member)
    owner_context = AuthorizationContext.build(principal: owner, organization:)
    member_context = AuthorizationContext.build(principal: member, organization:)
    project = Projects::Create.call(context: owner_context, name: "Protected", slug: "protected").project
    service_count = Service.count

    expect do
      described_class.call(
        context: member_context,
        project:,
        name: "Forbidden",
        workload_type: :worker,
        source_type: :oci,
        source_reference: "registry.example.com/worker@sha256:abc"
      )
    end.to raise_error(Pundit::NotAuthorizedError)

    expect(Service.count).to eq(service_count)
  end

  it "rejects a project from outside the selected organization" do
    first_owner = User.create!(email: "first-service-owner@example.com", name: "First")
    second_owner = User.create!(email: "second-service-owner@example.com", name: "Second")
    first_organization = Organizations::Create.call(principal: first_owner, name: "First Services").organization
    second_organization = Organizations::Create.call(principal: second_owner, name: "Second Services").organization
    first_context = AuthorizationContext.build(principal: first_owner, organization: first_organization)
    second_context = AuthorizationContext.build(principal: second_owner, organization: second_organization)
    foreign_project = Projects::Create.call(context: second_context, name: "Foreign", slug: "foreign").project

    expect do
      described_class.call(
        context: first_context,
        project: foreign_project,
        name: "Cross tenant",
        workload_type: :web,
        source_type: :git,
        source_reference: "github:foreign/repository"
      )
    end.to raise_error(Pundit::NotAuthorizedError)
  end
end
