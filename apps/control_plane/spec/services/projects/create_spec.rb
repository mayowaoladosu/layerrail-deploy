require "rails_helper"

RSpec.describe Projects::Create do
  it "creates a project with canonical production and staging environments" do
    owner = User.create!(email: "project-owner@example.com", name: "Project Owner")
    organization = Organizations::Create.call(principal: owner, name: "Acme").organization
    context = AuthorizationContext.build(principal: owner, organization:)

    result = described_class.call(
      context:,
      name: "  Customer API  ",
      slug: "Customer API"
    )

    expect(result.project).to have_attributes(
      organization:,
      name: "Customer API",
      slug: "customer-api",
      lifecycle_state: "active"
    )
    expect(result.project.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    expect(result.production_environment).to have_attributes(
      project: result.project,
      name: "Production",
      slug: "production",
      kind: "production",
      lifecycle_state: "active"
    )
    expect(result.staging_environment).to have_attributes(
      project: result.project,
      name: "Staging",
      slug: "staging",
      kind: "staging",
      lifecycle_state: "active"
    )
  end

  it "rejects a member before creating tenant state" do
    owner = User.create!(email: "member-owner@example.com", name: "Owner")
    member = User.create!(email: "project-member@example.com", name: "Member")
    organization = Organizations::Create.call(principal: owner, name: "Members").organization
    organization.memberships.create!(user: member, role: :member)
    context = AuthorizationContext.build(principal: member, organization:)
    project_count = Project.count
    environment_count = Environment.count

    expect do
      described_class.call(context:, name: "Forbidden", slug: "forbidden")
    end.to raise_error(Pundit::NotAuthorizedError)

    expect(Project.count).to eq(project_count)
    expect(Environment.count).to eq(environment_count)
  end

  it "rolls back both environments when project validation fails" do
    owner = User.create!(email: "rollback-owner@example.com", name: "Owner")
    organization = Organizations::Create.call(principal: owner, name: "Rollback").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    described_class.call(context:, name: "Existing", slug: "existing")
    environment_count = Environment.count

    expect do
      described_class.call(context:, name: "existing", slug: "different")
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(Project.where(organization:).count).to eq(1)
    expect(Environment.count).to eq(environment_count)
  end
end
