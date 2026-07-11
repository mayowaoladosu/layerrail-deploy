require "rails_helper"

RSpec.describe Organizations::Create do
  it "creates an organization with an owner membership" do
    principal = User.create!(email: " Owner@Example.COM ", name: "Owner")

    result = described_class.call(principal: principal, name: "Acme")

    expect(result.organization).to be_persisted
    expect(result.organization.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    expect(result.membership).to have_attributes(
      user: principal,
      organization: result.organization,
      role: "owner"
    )
    expect(principal.reload.email).to eq("owner@example.com")
  end

  it "rolls back tenant state when the organization is invalid" do
    principal = User.create!(email: "valid@example.com", name: "Valid")
    organization_count = Organization.count
    membership_count = Membership.count

    expect do
      described_class.call(principal:, name: " ")
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(Organization.count).to eq(organization_count)
    expect(Membership.count).to eq(membership_count)
  end

  it "rejects an unpersisted principal before opening a transaction" do
    principal = User.new(email: "new@example.com", name: "New")
    organization_count = Organization.count

    expect do
      described_class.call(principal:, name: "No owner")
    end.to raise_error(ArgumentError, "principal must be a persisted user")

    expect(Organization.count).to eq(organization_count)
  end
end
