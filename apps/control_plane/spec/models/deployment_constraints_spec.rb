require "rails_helper"

RSpec.describe "Deployment constraints" do
  def create_deployment
    owner = User.create!(email: "deployment-model@example.com", name: "Deployment")
    organization = Organizations::Create.call(principal: owner, name: "Deployment Model").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Deployment Model Project", slug: "deployment-model-project").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1"
    ).service
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: { "type" => "git", "reference" => "main", "commit_sha" => "1" * 40, "repository_id" => "repository-1" },
      idempotency_key: "deployment-model",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment

    [ context, deployment ]
  end

  it "prevents mutation of frozen deployment and configuration inputs" do
    _context, deployment = create_deployment

    expect do
      deployment.update!(source_digest: "0" * 64)
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect do
      deployment.configuration_snapshot.update!(payload_digest: "0" * 64)
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "keeps transition history append-only" do
    _context, deployment = create_deployment
    transition = deployment.deployment_transitions.sole

    expect { transition.update!(cause: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { transition.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it "uses UUIDv7 without database defaults for all new records" do
    _context, deployment = create_deployment
    records = [ deployment, deployment.configuration_snapshot, deployment.deployment_transitions.sole ]

    expect(records.map(&:id)).to all(match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/))
    expect([ Deployment, ConfigurationSnapshot, DeploymentTransition ].map { |model| model.columns_hash.fetch("id").default_function })
      .to all(be_nil)
  end
end
