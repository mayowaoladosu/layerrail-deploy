require "rails_helper"

RSpec.describe "Outbox command leasing" do
  def create_event(event_type: "deployment.requested.v1", key: "claim-event")
    owner = User.create!(email: "claim-owner-#{key}@example.com", name: "Claim Owner")
    organization = Organizations::Create.call(principal: owner, name: "Claim #{key}").organization
    OutboxEvents::Publish.call(
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type:,
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: key,
      producer: "control-plane",
      data: { "expected_version" => 0 }
    ).event
  end

  it "claims one supported event and replays the same request without another attempt" do
    event = create_event
    request_id = SecureRandom.uuid_v7
    now = event.available_at

    first = OutboxEvents::Claim.call(
      request_id:,
      event_types: [ "deployment.requested.v1" ],
      now:,
      lease_duration: 30.seconds
    )
    second = OutboxEvents::Claim.call(
      request_id:,
      event_types: [ "deployment.requested.v1" ],
      now: now + 1.second,
      lease_duration: 30.seconds
    )

    expect(first).to have_attributes(event:, replayed: false)
    expect(first.claim_token).to match(/\A[0-9a-f-]{36}\z/)
    expect(second).to have_attributes(
      event:,
      claim_token: first.claim_token,
      replayed: true
    )
    expect(event.reload).to have_attributes(
      status: "delivering",
      attempt_count: 1,
      claim_request_id: request_id,
      locked_until: now + 30.seconds
    )
  end

  it "filters unsupported event types and reclaims an expired lease" do
    ignored = create_event(event_type: "deployment.transitioned.v1", key: "ignored-event")
    event = create_event(key: "reclaimed-event")
    now = event.available_at
    first = OutboxEvents::Claim.call(
      request_id: SecureRandom.uuid_v7,
      event_types: [ "deployment.requested.v1" ],
      now:,
      lease_duration: 30.seconds
    )
    before_expiry = OutboxEvents::Claim.call(
      request_id: SecureRandom.uuid_v7,
      event_types: [ "deployment.requested.v1" ],
      now: now + 29.seconds,
      lease_duration: 30.seconds
    )
    reclaimed = OutboxEvents::Claim.call(
      request_id: SecureRandom.uuid_v7,
      event_types: [ "deployment.requested.v1" ],
      now: now + 31.seconds,
      lease_duration: 30.seconds
    )

    expect(before_expiry).to be_nil
    expect(reclaimed.event).to eq(event)
    expect(reclaimed.claim_token).not_to eq(first.claim_token)
    expect(event.reload.attempt_count).to eq(2)
    expect(ignored.reload.status).to eq("pending")
  end

  it "finalizes only the active claim and makes terminal completion idempotent" do
    event = create_event(key: "finalize-event")
    claim = OutboxEvents::Claim.call(
      request_id: SecureRandom.uuid_v7,
      event_types: [ "deployment.requested.v1" ],
      now: event.available_at,
      lease_duration: 30.seconds
    )

    expect do
      OutboxEvents::Finalize.call(
        event:,
        claim_token: SecureRandom.uuid_v7,
        outcome: OutboxEvents::DeliveryResult.published,
        now: Time.current
      )
    end.to raise_error(OutboxEvents::Finalize::StaleClaim)

    first = OutboxEvents::Finalize.call(
      event:,
      claim_token: claim.claim_token,
      outcome: OutboxEvents::DeliveryResult.published,
      now: Time.current
    )
    second = OutboxEvents::Finalize.call(
      event: event.reload,
      claim_token: claim.claim_token,
      outcome: OutboxEvents::DeliveryResult.published,
      now: Time.current
    )

    expect(first).to have_attributes(status: "published", replayed: false)
    expect(second).to have_attributes(status: "published", replayed: true)
    expect(event.reload).to have_attributes(status: "published", published_at: be_present)
  end

  it "uses the shared retry and dead-letter schedule" do
    event = create_event(key: "retry-event")

    5.times do |index|
      current = event.reload
      claim = OutboxEvents::Claim.call(
        request_id: SecureRandom.uuid_v7,
        event_types: [ "deployment.requested.v1" ],
        now: current.available_at,
        lease_duration: 30.seconds
      )
      result = OutboxEvents::Finalize.call(
        event:,
        claim_token: claim.claim_token,
        outcome: OutboxEvents::DeliveryResult.retry("Provider unavailable"),
        now: current.available_at
      )

      expect(result.status).to eq(index < 4 ? "pending" : "dead")
    end

    expect(event.reload).to have_attributes(
      status: "dead",
      attempt_count: 5,
      last_error: "Provider unavailable"
    )
  end
end
