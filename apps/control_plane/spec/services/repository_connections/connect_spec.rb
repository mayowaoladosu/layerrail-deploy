require "rails_helper"

RSpec.describe RepositoryConnections::Connect do
  def setup_domain(sequence)
    owner = User.create!(email: "repository-owner-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Repository Organization #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Repository Project #{sequence}", slug: "repository-project-#{sequence}").project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "pending"
    ).service
    provider = build_fake_git_provider
    installation = GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value

    [ context, organization, service, provider, installation ]
  end

  it "connects a service only to a repository authorized by its installation" do
    context, organization, service, provider, installation = setup_domain(1)

    result = described_class.call(
      context:,
      provider:,
      installation:,
      service:,
      provider_repository_id: "repository-1"
    )

    expect(result.value).to have_attributes(
      service:,
      git_installation: installation,
      organization:,
      provider_repository_id: "repository-1",
      owner: "layerrail",
      name: "api",
      full_name: "layerrail/api",
      private: true,
      default_branch: "main",
      status: "active"
    )
    expect(service.reload).to have_attributes(
      source_type: "git",
      source_reference: "github:repository-1"
    )
  end

  it "rejects a repository outside the installation without changing the service" do
    context, _organization, service, provider, installation = setup_domain(2)

    result = described_class.call(
      context:,
      provider:,
      installation:,
      service:,
      provider_repository_id: "repository-foreign"
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:repository_not_found)
    expect(RepositoryConnection).not_to exist
    expect(service.reload.source_reference).to eq("pending")
  end

  it "rejects cross-organization installations" do
    context, _organization, service, provider, = setup_domain(3)
    foreign_owner = User.create!(email: "foreign-installation-owner@example.com", name: "Foreign")
    foreign_organization = Organizations::Create.call(principal: foreign_owner, name: "Foreign Installation").organization
    foreign_installation = GitInstallation.create!(
      organization: foreign_organization,
      provider: :github,
      provider_installation_id: "installation-foreign",
      account_id: "account-foreign",
      account_login: "foreign",
      account_type: "organization",
      status: :active,
      permissions: { "contents" => "read" }
    )

    expect do
      described_class.call(
        context:,
        provider:,
        installation: foreign_installation,
        service:,
        provider_repository_id: "repository-1"
      )
    end.to raise_error(Pundit::NotAuthorizedError)
  end
end
