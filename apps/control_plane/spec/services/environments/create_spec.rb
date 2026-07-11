require "rails_helper"

RSpec.describe Environments::Create do
  it "creates a project-scoped custom environment with a branch mapping" do
    owner = User.create!(email: "environment-owner@example.com", name: "Environment Owner")
    organization = Organizations::Create.call(principal: owner, name: "Environments").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Platform", slug: "platform").project

    result = described_class.call(
      context:,
      project:,
      name: "  Quality Assurance  ",
      slug: "Quality Assurance",
      branch: "  qa  "
    )

    expect(result.environment).to have_attributes(
      project:,
      organization:,
      organization_id: organization.id,
      name: "Quality Assurance",
      slug: "quality-assurance",
      branch: "qa",
      kind: "custom",
      lifecycle_state: "active"
    )
  end

  it "rejects a member before creating an environment" do
    owner = User.create!(email: "environment-member-owner@example.com", name: "Owner")
    member = User.create!(email: "environment-member@example.com", name: "Member")
    organization = Organizations::Create.call(principal: owner, name: "Protected Environments").organization
    organization.memberships.create!(user: member, role: :member)
    owner_context = AuthorizationContext.build(principal: owner, organization:)
    member_context = AuthorizationContext.build(principal: member, organization:)
    project = Projects::Create.call(context: owner_context, name: "Protected", slug: "protected").project
    environment_count = Environment.count

    expect do
      described_class.call(context: member_context, project:, name: "Forbidden", slug: "forbidden")
    end.to raise_error(Pundit::NotAuthorizedError)

    expect(Environment.count).to eq(environment_count)
  end

  it "rejects a project outside the selected organization" do
    first_owner = User.create!(email: "first-environment-owner@example.com", name: "First")
    second_owner = User.create!(email: "second-environment-owner@example.com", name: "Second")
    first_organization = Organizations::Create.call(principal: first_owner, name: "First Environments").organization
    second_organization = Organizations::Create.call(principal: second_owner, name: "Second Environments").organization
    first_context = AuthorizationContext.build(principal: first_owner, organization: first_organization)
    second_context = AuthorizationContext.build(principal: second_owner, organization: second_organization)
    foreign_project = Projects::Create.call(context: second_context, name: "Foreign", slug: "foreign").project

    expect do
      described_class.call(context: first_context, project: foreign_project, name: "Cross tenant", slug: "cross-tenant")
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it "rejects a duplicate branch mapping" do
    owner = User.create!(email: "branch-owner@example.com", name: "Branch Owner")
    organization = Organizations::Create.call(principal: owner, name: "Branches").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Branches", slug: "branches").project
    described_class.call(context:, project:, name: "QA", slug: "qa", branch: "release")

    expect do
      described_class.call(context:, project:, name: "Demo", slug: "demo", branch: "release")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "does not allow an environment kind to change" do
    owner = User.create!(email: "kind-owner@example.com", name: "Kind Owner")
    organization = Organizations::Create.call(principal: owner, name: "Kinds").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Kinds", slug: "kinds").project
    environment = described_class.call(context:, project:, name: "QA", slug: "qa").environment

    expect(environment.update(kind: :production)).to be(false)
    expect(environment.errors[:kind]).to include("cannot be changed")
  end
end
