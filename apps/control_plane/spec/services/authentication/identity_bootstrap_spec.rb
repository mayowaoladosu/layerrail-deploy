require "rails_helper"

RSpec.describe Authentication::IdentityBootstrap do
  it "normalizes and stages the first identity without granting access early" do
    user = described_class.prepare(" Founder.User@Example.COM ")

    expect(user).to have_attributes(
      email: "founder.user@example.com",
      name: "Founder User",
      authentication_state: "bootstrap_candidate"
    )
    expect(user.organizations).to be_empty

    expect(described_class.activate(user.id)).to be(true)
    expect(user.reload).to be_authentication_state_active
    expect(user.organizations.sole.memberships.sole).to have_attributes(
      user:,
      role: "owner"
    )
  end

  it "allows provisioned identities and rejects unknown identities after bootstrap" do
    owner = User.create!(email: "owner@example.com", name: "Owner")
    organization = Organizations::Create.call(principal: owner, name: "Existing Organization").organization
    member = User.create!(email: "member@example.com", name: "Member")
    Membership.create!(user: member, organization:, role: :member)

    expect(described_class.prepare(member.email)).to eq(member)
    expect(described_class.activate(member.id)).to be(true)
    expect(described_class.prepare("unknown@example.com")).to be_nil
    expect(User.find_by(email: "unknown@example.com")).to be_nil
  end

  it "blocks an unverified bootstrap candidate once another identity wins" do
    first = described_class.prepare("first@example.com")
    second = described_class.prepare("second@example.com")

    expect(described_class.activate(first.id)).to be(true)
    expect(described_class.activate(second.id)).to be(false)
    expect(second.reload).to be_authentication_state_blocked
    expect(Organization.count).to eq(1)
    expect(Membership.where(role: :owner).count).to eq(1)
  end
end
