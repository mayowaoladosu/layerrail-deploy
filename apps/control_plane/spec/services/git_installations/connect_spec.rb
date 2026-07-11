require "rails_helper"

RSpec.describe GitInstallations::Connect do
  def create_context(sequence, role: :owner)
    owner = User.create!(email: "git-owner-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Git Organization #{sequence}").organization
    return [ AuthorizationContext.build(principal: owner, organization:), organization ] if role == :owner

    user = User.create!(email: "git-user-#{sequence}@example.com", name: "User #{sequence}")
    organization.memberships.create!(user:, role:)
    [ AuthorizationContext.build(principal: user, organization:), organization ]
  end

  it "persists provider-neutral installation metadata for an organization" do
    context, organization = create_context(1)

    result = described_class.call(
      context:,
      provider: build_fake_git_provider,
      provider_name: :github,
      provider_installation_id: "installation-1"
    )

    expect(result.value).to have_attributes(
      organization:,
      provider: "github",
      provider_installation_id: "installation-1",
      account_id: "account-1",
      account_login: "layerrail",
      account_type: "organization",
      status: "active",
      permissions: { "contents" => "read", "metadata" => "read" }
    )
    expect(result.value.attributes.keys).not_to include("token", "access_token", "secret")
  end

  it "refreshes the same organization installation idempotently" do
    context, = create_context(2)
    provider = build_fake_git_provider

    first = described_class.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value
    second = described_class.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value

    expect(second).to eq(first)
    expect(GitInstallation.where(provider: :github, provider_installation_id: "installation-1").count).to eq(1)
  end

  it "rejects member connection attempts before writing state" do
    context, = create_context(3, role: :member)

    expect do
      described_class.call(
        context:,
        provider: build_fake_git_provider,
        provider_name: :github,
        provider_installation_id: "installation-1"
      )
    end.to raise_error(Pundit::NotAuthorizedError)

    expect(GitInstallation).not_to exist
  end

  it "prevents one provider installation from crossing organizations" do
    first_context, = create_context(4)
    second_context, = create_context(5)
    provider = build_fake_git_provider
    described_class.call(
      context: first_context,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    )

    expect do
      described_class.call(
        context: second_context,
        provider:,
        provider_name: :github,
        provider_installation_id: "installation-1"
      )
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it "maps provider failures without persisting partial metadata" do
    context, = create_context(6)

    result = described_class.call(
      context:,
      provider: build_fake_git_provider,
      provider_name: :github,
      provider_installation_id: "missing"
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:installation_not_found)
    expect(GitInstallation).not_to exist
  end
end
