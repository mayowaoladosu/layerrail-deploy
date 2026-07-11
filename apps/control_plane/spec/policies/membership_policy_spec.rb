require "rails_helper"

RSpec.describe MembershipPolicy do
  def create_user(sequence)
    User.create!(email: "member-#{sequence}@example.com", name: "Member #{sequence}")
  end

  it "allows owners to manage memberships in their organization" do
    owner = create_user(1)
    organization = Organizations::Create.call(principal: owner, name: "Owned").organization
    membership = organization.memberships.create!(user: create_user(2), role: :member)
    context = AuthorizationContext.build(principal: owner, organization:)
    policy = described_class.new(context, membership)

    expect(policy).to be_show
    expect(policy).to be_update
    expect(policy).to be_destroy
  end

  it "prevents admins from changing an owner" do
    owner = create_user(3)
    admin = create_user(4)
    organization = Organizations::Create.call(principal: owner, name: "Administered").organization
    organization.memberships.create!(user: admin, role: :admin)
    owner_membership = organization.memberships.find_by!(user: owner)
    context = AuthorizationContext.build(principal: admin, organization:)
    policy = described_class.new(context, owner_membership)

    expect(policy).to be_show
    expect(policy).not_to be_update
    expect(policy).not_to be_destroy
  end

  it "reserves owner changes for a dedicated transfer workflow" do
    owner = create_user(5)
    organization = Organizations::Create.call(principal: owner, name: "Protected owner").organization
    owner_membership = organization.memberships.find_by!(user: owner)
    context = AuthorizationContext.build(principal: owner, organization:)
    policy = described_class.new(context, owner_membership)

    expect(policy).to be_show
    expect(policy).not_to be_update
    expect(policy).not_to be_destroy
  end

  it "fails closed for memberships in another organization" do
    owner = create_user(6)
    foreign_owner = create_user(7)
    own_organization = Organizations::Create.call(principal: owner, name: "Own").organization
    foreign_organization = Organizations::Create.call(principal: foreign_owner, name: "Foreign").organization
    foreign_membership = foreign_organization.memberships.find_by!(user: foreign_owner)
    context = AuthorizationContext.build(principal: owner, organization: own_organization)
    policy = described_class.new(context, foreign_membership)

    expect(policy).not_to be_show
    expect(policy).not_to be_update
    expect(policy).not_to be_destroy
  end
end
