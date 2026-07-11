require "rails_helper"

RSpec.describe EventConsumers::Process do
  def create_event
    owner = User.create!(email: "event-consumer@example.com", name: "Event Consumer")
    organization = Organizations::Create.call(principal: owner, name: "Event Consumer").organization
    event = OutboxEvents::Publish.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.transitioned.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "consumer-event-1",
      producer: "control-plane",
      data: { "status" => "queued" }
    ).event

    [ organization, event ]
  end

  it "persists the event receipt before one transactional side effect and replays its result" do
    organization, event = create_event
    calls = 0
    first = described_class.call(consumer: "local-provider", envelope: event.envelope) do
      calls += 1
      expect(EventReceipt.where(consumer: "local-provider", event_id: event.id)).to exist
      organization.update!(name: "Consumed once")
      { "organization_id" => organization.id }
    end
    second = described_class.call(consumer: "local-provider", envelope: event.envelope) do
      raise "replayed events must not execute the side effect"
    end

    expect(first.replayed).to be(false)
    expect(second).to have_attributes(replayed: true, result: first.result)
    expect(calls).to eq(1)
    expect(organization.reload.name).to eq("Consumed once")
    expect(EventReceipt.count).to eq(1)
    expect(first.receipt.inspect).to include("result=[REDACTED]")
    expect(first.receipt.inspect).not_to include(organization.id)
  end

  it "rolls back both receipt and database side effects after a crash, then retries once" do
    organization, event = create_event

    expect do
      described_class.call(consumer: "local-provider", envelope: event.envelope) do
        Project.create!(organization:, name: "Crashed", slug: "crashed")
        raise "simulated crash"
      end
    end.to raise_error("simulated crash")
    expect(EventReceipt.sole.status).to eq("processing")
    expect(Project).not_to exist

    result = described_class.call(consumer: "local-provider", envelope: event.envelope) do
      project = Project.create!(organization:, name: "Recovered", slug: "recovered")
      { "project_id" => project.id }
    end

    expect(result.replayed).to be(false)
    expect(Project.sole.name).to eq("Recovered")
    expect(EventReceipt.sole.status).to eq("completed")
  end

  it "rejects an altered replay with the same event ID" do
    _organization, event = create_event
    described_class.call(consumer: "local-provider", envelope: event.envelope) { {} }
    altered = event.envelope.deep_dup
    altered.fetch("data")["status"] = "failed"

    expect do
      described_class.call(consumer: "local-provider", envelope: altered) { {} }
    end.to raise_error(EventConsumers::Process::Conflict)
  end
end
