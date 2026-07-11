require "rails_helper"

RSpec.describe Revisions::MarkReady do
  it "makes a verified candidate eligible for traffic" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "revision-ready")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(deployment:, idempotency_key: "revision-ready-1", expected_lock_version: deployment.lock_version).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"e" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision

    readiness = { "status" => "passed", "checked_at" => Time.current.iso8601 }
    result = described_class.call(revision:, readiness:)
    replay = described_class.call(revision: revision.reload, readiness:)

    expect(result.revision).to have_attributes(status: "ready")
    expect(result.revision.readiness).to include("status" => "passed")
    expect(replay.revision).to eq(result.revision)
    expect(deployment.reload).to have_attributes(status: "ready", conclusion: "succeeded")
    expect do
      described_class.call(revision: revision.reload, readiness: readiness.merge("status" => "failed"))
    end.to raise_error(Revisions::MarkReady::ReadinessConflict)
    expect do
      revision.reload.update!(readiness: readiness.merge("checked_at" => 1.minute.from_now.iso8601))
    end.to raise_error(ActiveRecord::RecordNotSaved)
  end

  it "rejects readiness when supply-chain evidence did not pass" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "revision-scan")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(deployment:, idempotency_key: "revision-scan-1", expected_lock_version: deployment.lock_version).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"f" * 64}",
      evidence: { "scan_status" => "failed" },
      region: "local",
      cell: "development"
    ).revision

    expect do
      described_class.call(revision:, readiness: { "status" => "passed" })
    end.to raise_error(Revisions::MarkReady::EvidenceRejected)
  end
end
