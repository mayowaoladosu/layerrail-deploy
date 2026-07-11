require "rails_helper"

RSpec.describe GitWebhooks::Consume do
  def setup_domain
    owner = User.create!(email: "webhook-consumer@example.com", name: "Webhook Consumer")
    organization = Organizations::Create.call(principal: owner, name: "Webhook Consumer").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    provider = build_fake_git_provider
    installation = GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value
    project = Projects::Create.call(context:, name: "Webhook Project", slug: "webhook-project").project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "pending"
    ).service
    connection = RepositoryConnections::Connect.call(
      context:,
      provider:,
      installation:,
      service:,
      provider_repository_id: "repository-1"
    ).value

    [ organization, context, project, service, connection, provider ]
  end

  def setup_push(branch: "main", delivery_id: "delivery-consume")
    organization, context, project, service, connection, provider = setup_domain
    body = JSON.generate(
      installation: { id: "installation-1" },
      repository: { id: "repository-1" },
      ref: "refs/heads/#{branch}",
      before: "a" * 40,
      after: "b" * 40,
      pusher: { id: "provider-user-1" }
    )
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}"
    message = GitWebhooks::Ingest.call(
      provider:,
      provider_name: :github,
      delivery_id:,
      event_type: "push",
      signature:,
      body:
    ).value.message

    [ organization, context, project, service, connection, message ]
  end

  def setup_pull_request(action: "synchronize", delivery_id: "delivery-pr-consume")
    organization, context, project, service, connection, provider = setup_domain
    body = JSON.generate(
      action:,
      number: 42,
      installation: { id: "installation-1" },
      repository: { id: "repository-1" },
      pull_request: {
        head: { ref: "feature/preview", sha: "c" * 40 },
        base: { ref: "main" },
        merged: false
      },
      sender: { id: "provider-user-1" }
    )
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}"
    message = GitWebhooks::Ingest.call(
      provider:,
      provider_name: :github,
      delivery_id:,
      event_type: "pull_request",
      signature:,
      body:
    ).value.message

    [ organization, context, project, service, connection, message ]
  end

  it "transactionally consumes a configured push into one Deployment and command event" do
    organization, _context, project, service, _connection, message = setup_push

    first = described_class.call(message:)
    second = described_class.call(message: message.reload)

    expect(first).to have_attributes(replayed: false, ignored: false)
    expect(second).to have_attributes(
      deployment: first.deployment,
      event: first.event,
      replayed: true,
      ignored: false
    )
    expect(first.deployment).to have_attributes(
      organization:,
      project:,
      service:,
      environment: project.environments.find_by!(kind: :production),
      trigger: "webhook",
      status: "created",
      source_snapshot: include(
        "reference" => "main",
        "commit_sha" => "b" * 40,
        "repository_id" => "repository-1"
      )
    )
    expect(first.event).to have_attributes(
      organization:,
      resource_id: first.deployment.id,
      event_type: "deployment.requested.v1",
      correlation_id: first.deployment.correlation_id,
      status: "pending"
    )
    expect(first.event.data).to include(
      "deployment_id" => first.deployment.id,
      "expected_version" => first.deployment.lock_version,
      "configuration_snapshot_id" => first.deployment.configuration_snapshot_id
    )
    expect(message.reload).to have_attributes(
      status: "processed",
      deployment: first.deployment,
      processed_at: be_present,
      safe_error: nil
    )
    expect(Deployment.count).to eq(1)
    expect(OutboxEvent.where(event_type: "deployment.requested.v1").count).to eq(1)
    expect { message.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it "marks a push to an unconfigured branch processed without scheduling work" do
    _organization, _context, _project, _service, _connection, message = setup_push(
      branch: "feature/not-configured",
      delivery_id: "delivery-ignored-branch"
    )

    result = described_class.call(message:)

    expect(result).to have_attributes(deployment: nil, event: nil, replayed: false, ignored: true)
    expect(message.reload).to have_attributes(status: "processed", deployment: nil, safe_error: nil)
    expect(Deployment).not_to exist
    expect(OutboxEvent).not_to exist
  end

  it "creates a staging preview Deployment for an accepted pull-request revision" do
    _organization, _context, project, _service, _connection, message = setup_pull_request

    result = described_class.call(message:)

    expect(result).to have_attributes(replayed: false, ignored: false)
    expect(result.deployment).to have_attributes(
      environment: project.environments.find_by!(kind: :staging),
      source_snapshot: include(
        "reference" => "feature/preview",
        "commit_sha" => "c" * 40
      ),
      trigger: "webhook"
    )
    expect(result.event.event_type).to eq("deployment.requested.v1")
    expect(message.reload).to have_attributes(status: "processed", deployment: result.deployment)
  end

  it "acknowledges a closed pull request without creating a Deployment" do
    _organization, _context, _project, _service, _connection, message = setup_pull_request(
      action: "closed",
      delivery_id: "delivery-pr-closed"
    )

    result = described_class.call(message:)

    expect(result).to have_attributes(deployment: nil, event: nil, replayed: false, ignored: true)
    expect(message.reload.status).to eq("processed")
    expect(Deployment).not_to exist
  end

  it "fails closed when the repository connection is no longer active" do
    _organization, _context, _project, _service, connection, message = setup_push(
      delivery_id: "delivery-disconnected"
    )
    connection.update!(status: :disconnected)

    result = described_class.call(message:)

    expect(result).to have_attributes(deployment: nil, event: nil, replayed: false, ignored: true)
    expect(message.reload).to have_attributes(
      status: "failed",
      deployment: nil,
      safe_error: "Repository is not connected",
      processed_at: be_present
    )
    expect(Deployment).not_to exist
    expect(OutboxEvent).not_to exist
  end

  it "rolls back inbox outcome, Deployment and outbox together" do
    _organization, _context, _project, _service, _connection, message = setup_push(
      delivery_id: "delivery-transaction-rollback"
    )

    ApplicationRecord.transaction do
      described_class.call(message:)
      raise ActiveRecord::Rollback
    end

    expect(message.reload).to have_attributes(status: "pending", deployment: nil, processed_at: nil)
    expect(Deployment).not_to exist
    expect(OutboxEvent).not_to exist
  end
end
