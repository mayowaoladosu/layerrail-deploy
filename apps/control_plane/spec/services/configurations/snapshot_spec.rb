require "rails_helper"

RSpec.describe Configurations::Snapshot do
  def setup_domain(sequence, role: :owner)
    owner = User.create!(email: "config-owner-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Config Organization #{sequence}").organization
    principal = owner
    unless role == :owner
      principal = User.create!(email: "config-user-#{sequence}@example.com", name: "User #{sequence}")
      organization.memberships.create!(user: principal, role:)
    end
    context = AuthorizationContext.build(principal:, organization:)
    owner_context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context: owner_context, name: "Config Project #{sequence}", slug: "config-project-#{sequence}").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context: owner_context,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1"
    ).service

    [ context, project, environment, service ]
  end

  it "creates an immutable encrypted environment snapshot" do
    context, project, environment, service = setup_domain(1)

    result = described_class.call(
      context:,
      project:,
      environment:,
      service:,
      variables: {
        " DATABASE_URL " => { value: "postgres://secret", secret: true },
        "RAILS_ENV" => "production"
      }
    )
    version = result.version

    expect(version).to have_attributes(
      organization: project.organization,
      project:,
      environment:,
      service:,
      created_by: context.principal,
      scope_key: "service:#{service.id}",
      version: 1
    )
    expect(version.key_summary).to eq(
      [
        { "key" => "DATABASE_URL", "secret" => true },
        { "key" => "RAILS_ENV", "secret" => false }
      ]
    )
    expect(Configurations::Reveal.call(context:, version:).variables).to eq(
      "DATABASE_URL" => { "value" => "postgres://secret", "secret" => true },
      "RAILS_ENV" => { "value" => "production", "secret" => false }
    )
  end

  it "stores ciphertext and omits values from inspection and serialization" do
    context, project, environment, = setup_domain(2)
    version = described_class.call(
      context:,
      project:,
      environment:,
      variables: { "API_TOKEN" => { value: "super-secret-value", secret: true } }
    ).version
    raw = ApplicationRecord.connection.select_value(
      "SELECT payload_json FROM configuration_versions WHERE id = #{ApplicationRecord.connection.quote(version.id)}"
    )

    expect(raw).not_to include("super-secret-value")
    expect(raw).not_to eq(version.payload_json)
    expect(version.inspect).not_to include("super-secret-value")
    expect(version.as_json.to_s).not_to include("super-secret-value")
    expect(version.as_json).not_to have_key("payload_json")
  end

  it "increments versions independently for project and service scopes" do
    context, project, environment, service = setup_domain(3)

    project_first = described_class.call(context:, project:, environment:, variables: { "A" => "1" }).version
    project_second = described_class.call(context:, project:, environment:, variables: { "A" => "2" }).version
    service_first = described_class.call(context:, project:, environment:, service:, variables: { "A" => "3" }).version

    expect(project_first.version).to eq(1)
    expect(project_second.version).to eq(2)
    expect(service_first.version).to eq(1)
  end

  it "rejects members and cross-project resources before persistence" do
    member_context, project, environment, = setup_domain(4, role: :member)
    owner_context, foreign_project, _foreign_environment, foreign_service = setup_domain(5)

    expect do
      described_class.call(
        context: member_context,
        project:,
        environment:,
        variables: { "KEY" => "value" }
      )
    end.to raise_error(Pundit::NotAuthorizedError)

    expect do
      described_class.call(
        context: owner_context,
        project: foreign_project,
        environment: foreign_project.environments.first,
        service: foreign_service,
        variables: { "KEY" => "value" }
      )
    end.not_to raise_error

    expect do
      described_class.call(
        context: owner_context,
        project: foreign_project,
        environment: foreign_project.environments.first,
        service: project.services.build(name: "Wrong"),
        variables: { "KEY" => "value" }
      )
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects invalid keys, unsupported values, and oversized snapshots" do
    context, project, environment, = setup_domain(6)

    expect do
      described_class.call(context:, project:, environment:, variables: { "invalid-key" => "value" })
    end.to raise_error(Configurations::Snapshot::InvalidVariables)
    expect do
      described_class.call(context:, project:, environment:, variables: { "KEY" => Object.new })
    end.to raise_error(Configurations::Snapshot::InvalidVariables)
    expect do
      described_class.call(context:, project:, environment:, variables: { "KEY" => "x" * 33.kilobytes })
    end.to raise_error(Configurations::Snapshot::InvalidVariables)
    expect do
      described_class.call(
        context:,
        project:,
        environment:,
        variables: { " KEY " => "first", "KEY" => "second" }
      )
    end.to raise_error(Configurations::Snapshot::InvalidVariables)
  end

  it "allows members to inspect keys but not reveal values" do
    owner_context, project, environment, = setup_domain(7)
    version = described_class.call(
      context: owner_context,
      project:,
      environment:,
      variables: { "API_TOKEN" => { value: "secret", secret: true } }
    ).version
    member = User.create!(email: "config-reader@example.com", name: "Reader")
    project.organization.memberships.create!(user: member, role: :member)
    member_context = AuthorizationContext.build(principal: member, organization: project.organization)

    expect(ConfigurationVersionPolicy.new(member_context, version)).to be_show
    expect(ConfigurationVersionPolicy.new(member_context, version)).not_to be_reveal
    expect do
      Configurations::Reveal.call(context: member_context, version:)
    end.to raise_error(Pundit::NotAuthorizedError)
  end
end
