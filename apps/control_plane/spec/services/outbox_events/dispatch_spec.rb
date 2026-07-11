require "rails_helper"

RSpec.describe OutboxEvents::Dispatch do
  class TestPublisher
    attr_reader :envelopes

    def initialize(&handler)
      @handler = handler
      @envelopes = []
    end

    def publish(envelope:)
      @envelopes << envelope
      @handler.call(envelope)
    end
  end

  def create_event
    owner = User.create!(email: "outbox-dispatch@example.com", name: "Outbox Dispatch")
    organization = Organizations::Create.call(principal: owner, name: "Outbox Dispatch").organization
    event = OutboxEvents::Publish.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.transitioned.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "dispatch-event-1",
      producer: "control-plane",
      data: { "status" => "queued" }
    ).event

    [ organization, event ]
  end

  it "claims and publishes an eligible event once" do
    _organization, event = create_event
    publisher = TestPublisher.new { OutboxEvents::DeliveryResult.published }

    first = described_class.call(publisher:, now: event.available_at, limit: 10)
    second = described_class.call(publisher:, now: event.available_at, limit: 10)

    expect(first).to have_attributes(published: 1, retried: 0, dead: 0)
    expect(second).to have_attributes(published: 0, retried: 0, dead: 0)
    expect(event.reload).to have_attributes(status: "published", attempt_count: 1, published_at: be_present)
    expect(publisher.envelopes).to contain_exactly(event.envelope)
  end

  it "retries with the same event ID after an unknown publish outcome without duplicating the consumer side effect" do
    organization, event = create_event
    attempts = 0
    publisher = TestPublisher.new do |envelope|
      attempts += 1
      EventConsumers::Process.call(consumer: "local-provider", envelope:) do
        organization.update!(name: "Applied once")
        { "organization_id" => organization.id }
      end
      raise "connection dropped after publish" if attempts == 1

      OutboxEvents::DeliveryResult.published
    end

    first = described_class.call(publisher:, now: event.available_at, limit: 1)
    retry_at = event.reload.available_at
    second = described_class.call(publisher:, now: retry_at, limit: 1)

    expect(first).to have_attributes(published: 0, retried: 1, dead: 0)
    expect(second).to have_attributes(published: 1, retried: 0, dead: 0)
    expect(publisher.envelopes.map { |envelope| envelope.fetch("event_id") }.uniq).to eq([ event.id ])
    expect(EventReceipt.where(consumer: "local-provider", event_id: event.id).count).to eq(1)
    expect(organization.reload.name).to eq("Applied once")
  end

  it "marks a non-retryable result dead with only a safe error" do
    _organization, event = create_event
    publisher = TestPublisher.new do
      OutboxEvents::DeliveryResult.rejected("Unsupported event")
    end

    result = described_class.call(publisher:, now: event.available_at, limit: 1)

    expect(result).to have_attributes(published: 0, retried: 0, dead: 1)
    expect(event.reload).to have_attributes(
      status: "dead",
      attempt_count: 1,
      last_error: "Unsupported event"
    )
  end

  it "moves a repeatedly unavailable event to the dead state after five attempts" do
    _organization, event = create_event
    publisher = TestPublisher.new do
      OutboxEvents::DeliveryResult.retry("Provider unavailable")
    end
    results = 5.times.map do
      current = event.reload
      described_class.call(publisher:, now: current.available_at, limit: 1)
    end

    expect(results.sum(&:retried)).to eq(4)
    expect(results.sum(&:dead)).to eq(1)
    expect(event.reload).to have_attributes(
      status: "dead",
      attempt_count: 5,
      last_error: "Provider unavailable"
    )
  end
end
