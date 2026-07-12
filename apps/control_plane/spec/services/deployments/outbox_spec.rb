require "rails_helper"

RSpec.describe "Deployment transactional outbox" do
  it "appends one provider-neutral command when a Deployment is created or replayed" do
    context, _project, environment, service, deployment = create_deployment_domain(sequence: "deployment-outbox")
    replay = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: deployment.source_snapshot,
      idempotency_key: deployment.idempotency_key,
      correlation_id: deployment.correlation_id,
      trigger: :manual
    )
    event = OutboxEvent.where(resource_id: deployment.id, event_type: "deployment.requested.v1").sole

    expect(replay).to have_attributes(deployment:, replayed: true)
    expect(event.envelope.fetch("data")).to include(
      "deployment_id" => deployment.id,
      "service_id" => service.id,
      "environment_id" => environment.id,
      "expected_version" => deployment.lock_version,
      "configuration_snapshot_id" => deployment.configuration_snapshot_id,
      "source_digest" => deployment.source_digest,
      "source" => deployment.source_snapshot,
      "runtime_policy" => deployment.runtime_policy_snapshot,
      "configuration_present" => false,
      "immutable_hostname" => "d-#{deployment.id}.localhost",
      "container_port" => 8000
    )
    expect(event.envelope.to_s).not_to include("payload_json", "token", "secret")
    expect(OutboxEvent.where(resource_id: deployment.id, event_type: "deployment.requested.v1").count).to eq(1)

    advanced = advance_deployment(deployment, to: :queued, actor: context.principal)
    late_replay = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: deployment.source_snapshot,
      idempotency_key: deployment.idempotency_key,
      correlation_id: deployment.correlation_id,
      trigger: :manual
    )

    expect(late_replay).to have_attributes(deployment: advanced, replayed: true)
    expect(OutboxEvent.where(resource_id: deployment.id, event_type: "deployment.requested.v1").count).to eq(1)
  end

  it "appends each state transition in the same transaction" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "transition-outbox")
    created_event = OutboxEvent.where(
      resource_id: deployment.id,
      event_type: "deployment.transitioned.v1"
    ).sole

    result = Deployments::Transition.call(
      deployment:,
      to: :queued,
      actor: context.principal,
      cause: "queued_by_test",
      expected_lock_version: deployment.lock_version
    )
    queued_event = OutboxEvent.find_by!(
      resource_id: deployment.id,
      idempotency_key: "deployment:#{deployment.id}:transition:2"
    )

    expect(created_event.data).to include(
      "from_status" => nil,
      "to_status" => "created",
      "sequence" => 1
    )
    expect(queued_event.data).to include(
      "from_status" => "created",
      "to_status" => "queued",
      "sequence" => 2,
      "expected_version" => result.deployment.lock_version
    )

    ApplicationRecord.transaction do
      Deployments::Transition.call(
        deployment: result.deployment,
        to: :preparing,
        actor: nil,
        cause: "rolled_back",
        expected_lock_version: result.deployment.lock_version
      )
      raise ActiveRecord::Rollback
    end

    expect(deployment.reload.status).to eq("queued")
    expect(OutboxEvent.where(resource_id: deployment.id, event_type: "deployment.transitioned.v1").count).to eq(2)
  end
end
