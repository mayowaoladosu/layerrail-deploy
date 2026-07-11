require "rails_helper"

RSpec.describe "Deployment creation concurrency" do
  self.use_transactional_tests = false

  after do
    EventReceipt.delete_all
    OutboxEvent.delete_all
    GitWebhookInbox.delete_all
    DeploymentTransition.delete_all
    Deployment.delete_all
    ConfigurationSnapshot.delete_all
    ConfigurationVersion.delete_all
    RepositoryConnection.delete_all
    GitInstallation.delete_all
    Service.delete_all
    Environment.delete_all
    Project.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  it "creates one deployment and configuration snapshot for concurrent retries" do
    owner = User.create!(email: "deployment-concurrency@example.com", name: "Deployment")
    organization = Organizations::Create.call(principal: owner, name: "Deployment Concurrency").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Concurrent Deployment", slug: "concurrent-deployment").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1"
    ).service
    ready = Queue.new
    release = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          Deployments::Create.call(
            context:,
            service:,
            environment:,
            source: { "type" => "git", "reference" => "main", "commit_sha" => "f" * 40, "repository_id" => "repository-1" },
            idempotency_key: "concurrent-deployment",
            correlation_id: SecureRandom.uuid_v7,
            trigger: :manual
          )
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results.map { |result| result.deployment.id }.uniq.length).to eq(1)
    expect(results.count(&:replayed)).to eq(1)
    expect(Deployment.count).to eq(1)
    expect(ConfigurationSnapshot.count).to eq(1)
    expect(DeploymentTransition.count).to eq(1)
  end
end
