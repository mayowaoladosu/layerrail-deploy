require "rails_helper"

RSpec.describe "Outbox and consumer inbox constraints" do
  def create_event
    owner = User.create!(email: "event-constraints@example.com", name: "Event Constraints")
    organization = Organizations::Create.call(principal: owner, name: "Event Constraints").organization
    event = OutboxEvents::Publish.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.requested.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "event-constraints-1",
      producer: "control-plane",
      data: { "expected_version" => 0 }
    ).event

    [ organization, event ]
  end

  it "uses application-generated UUIDv7 IDs without database fallbacks" do
    _organization, event = create_event
    receipt = EventConsumers::Process.call(consumer: "test-consumer", envelope: event.envelope) { {} }.receipt

    expect([ event.id, receipt.id ]).to all(
      match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    )
    expect([ OutboxEvent, EventReceipt ].map { |model| model.columns_hash.fetch("id").default_function })
      .to all(be_nil)
  end

  it "keeps events and completed receipts append-only" do
    _organization, event = create_event
    receipt = EventConsumers::Process.call(consumer: "test-consumer", envelope: event.envelope) { {} }.receipt

    expect { event.update!(data: {}) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect do
      event.update!(status: :published, published_at: Time.current)
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect { event.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect { receipt.update!(result: { "changed" => true }) }.to raise_error(ActiveRecord::RecordNotSaved)
    expect { receipt.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it "rejects inconsistent delivery state in PostgreSQL" do
    organization, event = create_event
    timestamp = Time.current

    expect do
      OutboxEvent.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: organization.id,
        resource_id: event.resource_id,
        event_type: "deployment.requested.v1",
        correlation_id: event.correlation_id,
        idempotency_key: "inconsistent-delivery",
        producer: "control-plane",
        schema_version: 1,
        data: {},
        data_digest: Digest::SHA256.hexdigest("{}"),
        occurred_at: timestamp,
        status: "published",
        attempt_count: 0,
        available_at: timestamp,
        locked_until: nil,
        claim_token: nil,
        published_at: nil,
        last_error: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "rejects consumer receipts for an unknown organization in PostgreSQL" do
    _organization, event = create_event
    timestamp = Time.current

    expect do
      EventReceipt.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: SecureRandom.uuid_v7,
        consumer: "test-consumer",
        event_id: event.id,
        event_type: event.event_type,
        payload_digest: Digest::SHA256.hexdigest(JSON.generate(event.envelope)),
        status: "completed",
        result: {},
        consumed_at: timestamp,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects a cross-organization webhook Deployment outcome in PostgreSQL" do
    owner = User.create!(email: "webhook-outcome-owner@example.com", name: "Webhook Outcome")
    organization = Organizations::Create.call(principal: owner, name: "Webhook Outcome").organization
    installation = GitInstallation.create!(
      organization:,
      provider: :github,
      provider_installation_id: "webhook-outcome-installation",
      account_id: "webhook-outcome-account",
      account_login: "webhook-outcome",
      account_type: "organization",
      status: :active,
      permissions: { "contents" => "read" }
    )
    message = GitWebhookInbox.create!(
      organization:,
      git_installation: installation,
      provider: :github,
      delivery_id: "webhook-outcome-delivery",
      event_type: "git.push.v1",
      provider_repository_id: "repository-1",
      occurred_at: Time.current,
      payload_digest: "a" * 64,
      data: { "ref" => "main", "after_sha" => "b" * 40 },
      status: :pending
    )
    _context, _project, _environment, _service, foreign_deployment =
      create_deployment_domain(sequence: "foreign-webhook-outcome")

    expect do
      GitWebhookInbox.where(id: message.id).update_all(
        deployment_id: foreign_deployment.id,
        status: "processed",
        processed_at: Time.current
      )
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
