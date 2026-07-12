require "rails_helper"

RSpec.describe LocalProviderEvents::Consume do
  def setup_oci_deployment(sequence:)
    context, project, environment, service, _deployment = create_deployment_domain(sequence: "provider-#{sequence}")
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "oci",
        "reference" => "lrail-local-sample:dev",
        "digest" => "sha256:#{Digest::SHA256.hexdigest(sequence)}"
      },
      idempotency_key: "provider-deployment-#{sequence}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
    command = OutboxEvent.find_by!(resource_id: deployment.id, event_type: "deployment.requested.v1")

    [ context, project, environment, service, deployment, command ]
  end

  def envelope(deployment:, command:, event_type:, data:)
    {
      "event_id" => SecureRandom.uuid_v7,
      "event_type" => event_type,
      "occurred_at" => Time.current.iso8601(6),
      "organization_id" => deployment.organization_id,
      "resource_id" => deployment.id,
      "correlation_id" => deployment.correlation_id,
      "idempotency_key" => "local-provider:#{command.id}:#{event_type}",
      "producer" => "local-provider",
      "schema_version" => 1,
      "data" => {
        "deployment_id" => deployment.id,
        "operation_id" => command.id,
        "expected_version" => 0
      }.merge(data)
    }
  end

  it "turns one ready callback into a verified ready Revision and replays once" do
    _context, _project, _environment, service, deployment, command = setup_oci_deployment(sequence: "ready")
    callback = envelope(
      deployment:,
      command:,
      event_type: "deployment.runtime.ready.v1",
      data: {
        "artifact_digest" => deployment.source_snapshot.fetch("digest"),
        "region" => "local",
        "cell" => "docker-desktop",
        "readiness" => {
          "status" => "passed",
          "checked_at" => Time.current.iso8601(6)
        }
      }
    )

    first = described_class.call(envelope: callback)
    second = described_class.call(envelope: callback)
    revision = Revision.find(first.result.fetch("revision_id"))

    expect(first.replayed).to be(false)
    expect(second).to have_attributes(result: first.result, replayed: true)
    expect(first.result).to include(
      "deployment_id" => deployment.id,
      "revision_id" => revision.id,
      "ignored" => false
    )
    expect(deployment.reload).to have_attributes(status: "ready", conclusion: "succeeded")
    expect(revision).to have_attributes(
      service:,
      artifact_digest: deployment.source_snapshot.fetch("digest"),
      status: "ready",
      region: "local",
      cell: "docker-desktop"
    )
    expect(revision.build.evidence).to include(
      "scan_status" => "passed",
      "provider_operation_id" => command.id
    )
    expect(EventReceipt.where(consumer: "local-provider", event_id: callback.fetch("event_id")).count).to eq(1)
  end

  it "ignores a valid callback whose expected version became stale" do
    context, _project, _environment, _service, deployment, command = setup_oci_deployment(sequence: "stale")
    Deployments::Transition.call(
      deployment:,
      to: :canceling,
      actor: context.principal,
      cause: "cancellation_requested",
      expected_lock_version: deployment.lock_version
    )
    callback = envelope(
      deployment:,
      command:,
      event_type: "deployment.runtime.ready.v1",
      data: {
        "artifact_digest" => deployment.source_snapshot.fetch("digest"),
        "region" => "local",
        "cell" => "docker-desktop",
        "readiness" => { "status" => "passed" }
      }
    )

    result = described_class.call(envelope: callback)

    expect(result.result).to eq(
      "deployment_id" => deployment.id,
      "revision_id" => nil,
      "ignored" => true
    )
    expect(deployment.reload.status).to eq("canceling")
    expect(Build.where(deployment:)).not_to exist
  end

  it "records one structured provider failure" do
    _context, _project, _environment, _service, deployment, command = setup_oci_deployment(sequence: "failed")
    callback = envelope(
      deployment:,
      command:,
      event_type: "deployment.runtime.failed.v1",
      data: {
        "phase" => "runtime",
        "code" => "readiness_failed",
        "message" => "Sample application did not become ready",
        "diagnostic_reference" => "local-provider:readiness"
      }
    )

    result = described_class.call(envelope: callback)

    expect(result.result).to include("deployment_id" => deployment.id, "ignored" => false)
    expect(deployment.reload).to have_attributes(status: "failed", conclusion: "failed")
    expect(deployment.deployment_transitions.order(:sequence).last.error).to eq(
      "phase" => "runtime",
      "code" => "readiness_failed",
      "message" => "Sample application did not become ready",
      "diagnostic_reference" => "local-provider:readiness"
    )
  end

  it "completes a cancellation callback bound to its command" do
    context, _project, _environment, _service, deployment, _command = setup_oci_deployment(sequence: "canceled")
    canceled = Deployments::Cancel.call(
      context:,
      deployment:,
      expected_lock_version: deployment.lock_version
    ).deployment
    command = OutboxEvent.find_by!(
      resource_id: deployment.id,
      event_type: "deployment.cancellation.requested.v1"
    )
    callback = envelope(
      deployment:,
      command:,
      event_type: "deployment.runtime.canceled.v1",
      data: {}
    )
    callback["data"]["expected_version"] = canceled.lock_version

    result = described_class.call(envelope: callback)

    expect(result.result).to include("deployment_id" => deployment.id, "ignored" => false)
    expect(deployment.reload).to have_attributes(status: "canceled", conclusion: "canceled")
    expect(Build.where(deployment:)).not_to exist
  end

  it "rejects callbacks that are not bound to the organization, command and OCI artifact" do
    _context, _project, _environment, _service, deployment, command = setup_oci_deployment(sequence: "invalid")
    callback = envelope(
      deployment:,
      command:,
      event_type: "deployment.runtime.ready.v1",
      data: {
        "artifact_digest" => "sha256:#{"f" * 64}",
        "region" => "local",
        "cell" => "docker-desktop",
        "readiness" => { "status" => "passed" }
      }
    )

    expect do
      described_class.call(envelope: callback)
    end.to raise_error(LocalProviderEvents::Consume::InvalidEvent)
    expect(deployment.reload.status).to eq("created")
    expect(EventReceipt.where(event_id: callback.fetch("event_id"))).not_to exist

    callback["organization_id"] = SecureRandom.uuid_v7
    expect do
      described_class.call(envelope: callback)
    end.to raise_error(LocalProviderEvents::Consume::InvalidEvent)
  end
end
