require "rails_helper"

require "json_schemer"

RSpec.describe OutboxEvents::Publish do
  def create_organization
    owner = User.create!(email: "outbox-publisher@example.com", name: "Outbox Publisher")
    Organizations::Create.call(principal: owner, name: "Outbox Publisher").organization
  end

  def publish(organization:, data: { "status" => "queued" })
    described_class.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.transitioned.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "deployment:transition:1",
      producer: "control-plane",
      data:
    )
  end

  it "persists one immutable canonical event and replays an identical publish" do
    organization = create_organization
    first = publish(organization:)
    second = described_class.call(
      organization:,
      resource_id: first.event.resource_id,
      event_type: first.event.event_type,
      correlation_id: first.event.correlation_id,
      idempotency_key: first.event.idempotency_key,
      producer: first.event.producer,
      data: first.event.data
    )
    schema_path = Rails.root.join("../../contracts/events/v1/event-envelope.schema.json").expand_path
    schema = JSONSchemer.schema(JSON.parse(schema_path.read))

    expect(first.replayed).to be(false)
    expect(second).to have_attributes(event: first.event, replayed: true)
    expect(schema).to be_valid(first.event.envelope)
    expect(first.event).to have_attributes(status: "pending", attempt_count: 0)
    expect(first.event.inspect).to include("data=[REDACTED]")
    expect(first.event.inspect).not_to include("queued")
    expect(OutboxEvent.count).to eq(1)
    expect do
      first.event.update!(data: { "status" => "changed" })
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "rejects reuse of an idempotency key for a different event" do
    organization = create_organization
    first = publish(organization:)

    expect do
      described_class.call(
        organization:,
        resource_id: first.event.resource_id,
        event_type: first.event.event_type,
        correlation_id: first.event.correlation_id,
        idempotency_key: first.event.idempotency_key,
        producer: first.event.producer,
        data: { "status" => "failed" }
      )
    end.to raise_error(OutboxEvents::Publish::Conflict)
  end

  it "rolls the event back with its surrounding domain transaction" do
    organization = create_organization

    expect do
      ApplicationRecord.transaction do
        publish(organization:)
        raise ActiveRecord::Rollback
      end
    end.not_to change(OutboxEvent, :count)
  end
end
