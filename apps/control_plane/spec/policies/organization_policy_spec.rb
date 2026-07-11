require "rails_helper"

RSpec.describe OrganizationPolicy do
  def create_user(sequence)
    User.create!(email: "user-#{sequence}@example.com", name: "User #{sequence}")
  end

  def create_organization(principal, name)
    Organizations::Create.call(principal:, name:).organization
  end

  it "allows an owner to view, update and manage their organization" do
    principal = create_user(1)
    organization = create_organization(principal, "Owned")
    context = AuthorizationContext.build(principal:, organization:)
    policy = described_class.new(context, organization)

    expect(policy).to be_show
    expect(policy).to be_update
    expect(policy).to be_manage_members
  end

  it "allows a member to view but not manage their organization" do
    owner = create_user(2)
    member = create_user(3)
    organization = create_organization(owner, "Shared")
    organization.memberships.create!(user: member, role: :member)
    context = AuthorizationContext.build(principal: member, organization:)
    policy = described_class.new(context, organization)

    expect(policy).to be_show
    expect(policy).not_to be_update
    expect(policy).not_to be_manage_members
  end

  it "fails closed for a principal from another organization" do
    principal = create_user(4)
    foreign_owner = create_user(5)
    own_organization = create_organization(principal, "Own")
    foreign_organization = create_organization(foreign_owner, "Foreign")
    context = AuthorizationContext.build(principal:, organization: foreign_organization)
    policy = described_class.new(context, foreign_organization)

    expect(policy).not_to be_show
    expect(policy).not_to be_update
    expect(policy).not_to be_manage_members
    expect(described_class::Scope.new(context, Organization.all).resolve).to be_empty
    expect(own_organization).to be_persisted
  end

  it "never authorizes a record outside the selected organization" do
    principal = create_user(6)
    own_organization = create_organization(principal, "Selected")
    foreign_organization = create_organization(create_user(7), "Other")
    context = AuthorizationContext.build(principal:, organization: own_organization)

    expect(described_class.new(context, foreign_organization)).not_to be_show
    expect(described_class::Scope.new(context, Organization.all).resolve).to contain_exactly(own_organization)
  end
end
