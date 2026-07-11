require "rails_helper"

RSpec.describe Deployments::Create do
  def setup_domain
    owner = User.create!(email: "deployment-owner@example.com", name: "Deployment Owner")
    organization = Organizations::Create.call(principal: owner, name: "Deployment Organization").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Deployment Project", slug: "deployment-project").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1",
      runtime_policy: { "readiness_path" => "/health", "graceful_shutdown_seconds" => 30 }
    ).service
    Configurations::Snapshot.call(
      context:,
      project:,
      environment:,
      variables: { "RAILS_ENV" => "production", "API_TOKEN" => { value: "project-secret", secret: true } }
    )
    Configurations::Snapshot.call(
      context:,
      project:,
      environment:,
      service:,
      variables: { "API_TOKEN" => { value: "service-secret", secret: true }, "PORT" => "3000" }
    )

    [ context, project, environment, service ]
  end

  it "creates one immutable deployment with a resolved encrypted configuration snapshot" do
    context, project, environment, service = setup_domain

    result = described_class.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "git",
        "reference" => "main",
        "commit_sha" => "a" * 40,
        "repository_id" => "repository-1"
      },
      idempotency_key: "deploy-api-main-aaaa",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    )
    deployment = result.deployment

    expect(deployment).to have_attributes(
      organization: project.organization,
      project:,
      service:,
      environment:,
      status: "created",
      conclusion: nil,
      trigger: "manual",
      source_snapshot: {
        "type" => "git",
        "reference" => "main",
        "commit_sha" => "a" * 40,
        "repository_id" => "repository-1"
      },
      runtime_policy_snapshot: service.runtime_policy
    )
    expect(deployment.configuration_snapshot.key_summary).to eq(
      [
        { "key" => "API_TOKEN", "secret" => true },
        { "key" => "PORT", "secret" => false },
        { "key" => "RAILS_ENV", "secret" => false }
      ]
    )
    expect(Configurations::RevealSnapshot.call(context:, snapshot: deployment.configuration_snapshot).variables)
      .to eq(
        "API_TOKEN" => { "value" => "service-secret", "secret" => true },
        "PORT" => { "value" => "3000", "secret" => false },
        "RAILS_ENV" => { "value" => "production", "secret" => false }
      )
    expect(deployment.deployment_transitions.sole).to have_attributes(
      from_status: nil,
      to_status: "created",
      actor_type: "user",
      actor_id: context.principal.id,
      cause: "manual"
    )
  end

  it "returns the existing deployment for the same organization idempotency key" do
    context, _project, environment, service = setup_domain
    attributes = {
      context:,
      service:,
      environment:,
      source: { "type" => "git", "reference" => "main", "commit_sha" => "b" * 40, "repository_id" => "repository-1" },
      idempotency_key: "deploy-replay",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    }

    first = described_class.call(**attributes)
    second = described_class.call(**attributes.merge(correlation_id: SecureRandom.uuid_v7))

    expect(second.deployment).to eq(first.deployment)
    expect(second.replayed).to be(true)
    expect(Deployment.count).to eq(1)
  end

  it "rejects a reused key with a different source" do
    context, _project, environment, service = setup_domain
    base = {
      context:,
      service:,
      environment:,
      idempotency_key: "deploy-conflict",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    }
    described_class.call(**base, source: { "type" => "git", "reference" => "main", "commit_sha" => "c" * 40, "repository_id" => "repository-1" })

    expect do
      described_class.call(**base, source: { "type" => "git", "reference" => "main", "commit_sha" => "d" * 40, "repository_id" => "repository-1" })
    end.to raise_error(Deployments::Create::IdempotencyConflict)
  end
end
