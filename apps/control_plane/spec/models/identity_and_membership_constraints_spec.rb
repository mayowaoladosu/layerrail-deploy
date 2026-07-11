require "rails_helper"

RSpec.describe "Identity and membership constraints" do
  def create_user(sequence)
    User.create!(email: "constraint-#{sequence}@example.com", name: "User #{sequence}")
  end

  it "enforces normalized email uniqueness in PostgreSQL" do
    user = User.create!(email: "Unique@Example.com", name: "Unique")
    timestamp = Time.current

    expect do
      User.insert_all!([ {
        id: SecureRandom.uuid_v7,
        email: user.email,
        name: "Duplicate",
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "enforces one membership per user and organization" do
    owner = create_user(1)
    organization = Organizations::Create.call(principal: owner, name: "Unique membership").organization

    duplicate = organization.memberships.new(user: owner, role: :member)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors.of_kind?(:user_id, :taken)).to be(true)
  end

  it "rejects unsupported roles in both the model and database" do
    owner = create_user(2)
    user = create_user(3)
    organization = Organizations::Create.call(principal: owner, name: "Roles").organization
    membership = organization.memberships.new(user:, role: "super_admin")
    timestamp = Time.current

    expect(membership).not_to be_valid
    expect do
      Membership.insert_all!([ {
        id: SecureRandom.uuid_v7,
        user_id: user.id,
        organization_id: organization.id,
        role: "super_admin",
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
