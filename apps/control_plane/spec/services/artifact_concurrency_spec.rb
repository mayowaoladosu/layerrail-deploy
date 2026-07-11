require "rails_helper"

RSpec.describe "Build and Alias concurrency" do
  self.use_transactional_tests = false

  after do
    EventReceipt.delete_all
    OutboxEvent.delete_all
    Alias.delete_all
    Revision.delete_all
    Build.delete_all
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

  def make_ready(context:, deployment:, sequence:)
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "build-#{sequence}",
      expected_lock_version: deployment.lock_version
    ).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{Digest::SHA256.hexdigest(sequence)}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision

    Revisions::MarkReady.call(revision:, readiness: { "status" => "passed" }).revision
  end

  it "creates one Build when the same start command races" do
    context, _project, _environment, _service, deployment =
      create_deployment_domain(sequence: "concurrent-build")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    expected_lock_version = deployment.lock_version
    ready = Queue.new
    release = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          Builds::Start.call(
            deployment: Deployment.find(deployment.id),
            idempotency_key: "concurrent-build-start",
            expected_lock_version:
          )
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results.count(&:replayed)).to eq(1)
    expect(results.map { |result| result.build.id }.uniq.one?).to be(true)
    expect(Build.where(deployment_id: deployment.id).count).to eq(1)
  end

  it "serializes competing promotions into one consistent Alias history" do
    context, _project, environment, service, first_deployment =
      create_deployment_domain(sequence: "concurrent-alias-domain")
    first_revision = make_ready(
      context:,
      deployment: first_deployment,
      sequence: "concurrent-alias-first"
    )
    second_deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "git",
        "reference" => "main",
        "commit_sha" => Digest::SHA1.hexdigest("concurrent-alias-second"),
        "repository_id" => "repository-1"
      },
      idempotency_key: "deployment-concurrent-alias-second",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
    second_revision = make_ready(
      context:,
      deployment: second_deployment,
      sequence: "concurrent-alias-second"
    )
    ready = Queue.new
    release = Queue.new

    threads = [ first_revision.id, second_revision.id ].map do |revision_id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          thread_context = AuthorizationContext.build(
            principal: User.find(context.principal.id),
            organization: Organization.find(context.organization.id)
          )
          ready << true
          release.pop
          Aliases::Promote.call(
            context: thread_context,
            revision: Revision.find(revision_id),
            alias_type: :environment,
            name: environment.slug
          )
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)
    alias_record = Alias.sole

    expect(results.length).to eq(2)
    expect([ alias_record.current_revision_id, alias_record.previous_revision_id ].sort)
      .to eq([ first_revision.id, second_revision.id ].sort)
    expect(alias_record.current_revision.deployment.reload.status).to eq("promoted")
    expect(alias_record.previous_revision.deployment.reload.status).to eq("superseded")
  end
end
