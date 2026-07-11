require "rails_helper"

RSpec.describe "System authorization context" do
  it "permits only automated Deployment/configuration creation in its selected organization" do
    first_owner = User.create!(email: "system-first@example.com", name: "System First")
    first = Organizations::Create.call(principal: first_owner, name: "System First").organization
    second_owner = User.create!(email: "system-second@example.com", name: "System Second")
    second = Organizations::Create.call(principal: second_owner, name: "System Second").organization
    context = AuthorizationContext.system(organization: first)

    expect(context).to be_system
    expect(context).not_to be_member
    expect(context.principal).to be_nil
    expect(DeploymentPolicy.new(context, Deployment.new(organization: first))).to be_create
    expect(ConfigurationSnapshotPolicy.new(context, ConfigurationSnapshot.new(organization: first))).to be_create
    expect(DeploymentPolicy.new(context, Deployment.new(organization: second))).not_to be_create
    expect(ConfigurationSnapshotPolicy.new(context, ConfigurationSnapshot.new(organization: second))).not_to be_create
    expect(ProjectPolicy.new(context, Project.new(organization: first))).not_to be_create
    expect(AliasPolicy.new(context, Alias.new(organization: first))).not_to be_promote
  end
end
