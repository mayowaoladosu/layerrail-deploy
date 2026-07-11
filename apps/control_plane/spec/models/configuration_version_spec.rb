require "rails_helper"

RSpec.describe ConfigurationVersion do
  it "cannot be updated or destroyed after creation" do
    owner = User.create!(email: "immutable-config@example.com", name: "Immutable")
    organization = Organizations::Create.call(principal: owner, name: "Immutable Config").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Immutable Project", slug: "immutable-project").project
    environment = project.environments.find_by!(kind: :production)
    version = Configurations::Snapshot.call(
      context:,
      project:,
      environment:,
      variables: { "KEY" => "value" }
    ).version

    expect do
      version.update!(payload_digest: "0" * 64)
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { version.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it "uses application-generated UUIDv7 without a database default" do
    expect(described_class.columns_hash.fetch("id").default_function).to be_nil
  end
end
