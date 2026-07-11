module DeploymentDomainFixtures
  def create_deployment_domain(sequence: SecureRandom.hex(4))
    owner = User.create!(email: "deployment-fixture-#{sequence}@example.com", name: "Deployment #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Deployment Fixture #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Fixture Project #{sequence}", slug: "fixture-project-#{sequence}").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1",
      runtime_policy: { "readiness_path" => "/health" }
    ).service
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: { "type" => "git", "reference" => "main", "commit_sha" => Digest::SHA1.hexdigest(sequence.to_s), "repository_id" => "repository-1" },
      idempotency_key: "deployment-fixture-#{sequence}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment

    [ context, project, environment, service, deployment ]
  end

  def advance_deployment(deployment, to:, actor: nil)
    Deployments::Transition.call(
      deployment:,
      to:,
      actor:,
      cause: "fixture",
      expected_lock_version: deployment.lock_version
    ).deployment
  end
end

RSpec.configure do |config|
  config.include DeploymentDomainFixtures
end
