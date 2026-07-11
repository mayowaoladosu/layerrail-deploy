require "rails_helper"

RSpec.describe "Git connection constraints" do
  def create_domain(sequence)
    owner = User.create!(email: "git-constraint-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Git Constraint #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Git Project #{sequence}", slug: "git-project-#{sequence}").project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "pending"
    ).service
    installation = GitInstallation.create!(
      organization:,
      provider: :github,
      provider_installation_id: "installation-#{sequence}",
      account_id: "account-#{sequence}",
      account_login: "account-#{sequence}",
      account_type: "organization",
      status: :active,
      permissions: { "contents" => "read" }
    )

    [ organization, project, service, installation ]
  end

  it "has no token columns or database-generated UUID fallbacks" do
    expect(GitInstallation.column_names).not_to include("token", "access_token", "secret")
    expect(RepositoryConnection.column_names).not_to include("token", "access_token", "secret")
    expect(GitInstallation.columns_hash.fetch("id").default_function).to be_nil
    expect(RepositoryConnection.columns_hash.fetch("id").default_function).to be_nil
    expect(GitWebhookInbox.column_names).not_to include("body", "payload", "raw_payload")
    expect(GitWebhookInbox.columns_hash.fetch("id").default_function).to be_nil
  end

  it "rejects cross-organization installation ownership in PostgreSQL" do
    first_organization, first_project, first_service, = create_domain(1)
    _second_organization, _second_project, _second_service, second_installation = create_domain(2)
    timestamp = Time.current

    expect do
      RepositoryConnection.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: first_organization.id,
        project_id: first_project.id,
        service_id: first_service.id,
        git_installation_id: second_installation.id,
        provider_repository_id: "cross-installation",
        owner: "layerrail",
        name: "cross",
        full_name: "layerrail/cross",
        private: true,
        default_branch: "main",
        status: "active",
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects cross-project service ownership in PostgreSQL" do
    first_organization, first_project, _first_service, first_installation = create_domain(3)
    _second_organization, _second_project, second_service, = create_domain(4)
    timestamp = Time.current

    expect do
      RepositoryConnection.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: first_organization.id,
        project_id: first_project.id,
        service_id: second_service.id,
        git_installation_id: first_installation.id,
        provider_repository_id: "cross-service",
        owner: "layerrail",
        name: "cross",
        full_name: "layerrail/cross",
        private: true,
        default_branch: "main",
        status: "active",
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
