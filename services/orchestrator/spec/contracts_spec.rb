# frozen_string_literal: true

RSpec.describe LrailOrchestrator::Contracts do
  let(:deployment_id) { "019b9a80-0000-7000-8000-000000000003" }
  let(:organization_id) { "019b9a80-0000-7000-8000-000000000002" }
  let(:event_id) { "019b9a80-0000-7000-8000-000000000010" }
  let(:envelope) do
    {
      "event_id" => event_id,
      "event_type" => "deployment.requested.v1",
      "occurred_at" => "2026-07-11T22:00:00Z",
      "organization_id" => organization_id,
      "resource_id" => deployment_id,
      "correlation_id" => "019b9a80-0000-7000-8000-000000000004",
      "idempotency_key" => "deployment:#{deployment_id}:requested",
      "producer" => "control-plane",
      "schema_version" => 1,
      "data" => {
        "deployment_id" => deployment_id,
        "service_id" => "019b9a80-0000-7000-8000-000000000011",
        "environment_id" => "019b9a80-0000-7000-8000-000000000012",
        "configuration_snapshot_id" => "019b9a80-0000-7000-8000-000000000013",
        "source_digest" => "a" * 64,
        "source" => {
          "type" => "git",
          "reference" => "https://credential@example.invalid/repository.git"
        },
        "runtime_policy" => { "readiness_path" => "/health" },
        "workload_type" => "web",
        "expected_version" => 0,
        "untrusted_label" => "customer value"
      }
    }
  end

  it "reduces an event to a bounded primitive workflow input" do
    input = described_class.deployment_input(envelope)
    serialized = JSON.generate(input)

    expect(input).to eq(
      "contract_version" => 1,
      "event_id" => event_id,
      "organization_id" => organization_id,
      "deployment_id" => deployment_id,
      "service_id" => "019b9a80-0000-7000-8000-000000000011",
      "environment_id" => "019b9a80-0000-7000-8000-000000000012",
      "configuration_snapshot_id" => "019b9a80-0000-7000-8000-000000000013",
      "source_digest" => "sha256:#{"a" * 64}",
      "workload_type" => "web",
      "expected_version" => 0,
      "operation_id" => event_id
    )
    expect(serialized.bytesize).to be < described_class::MAX_BYTES
    expect(serialized).not_to match(%r{https?://|credential|reference|readiness_path|untrusted_label})
  end

  it "rejects invalid identities, digests and enums" do
    expect do
      described_class.deployment_input(
        envelope.merge("resource_id" => "../deployment")
      )
    end.to raise_error(described_class::Invalid)

    invalid_digest = Marshal.load(Marshal.dump(envelope))
    invalid_digest["data"]["source_digest"] = "latest"
    expect { described_class.deployment_input(invalid_digest) }
      .to raise_error(described_class::Invalid)

    invalid_type = Marshal.load(Marshal.dump(envelope))
    invalid_type["data"]["workload_type"] = "worker"
    expect { described_class.deployment_input(invalid_type) }
      .to raise_error(described_class::Invalid)
  end

  it "validates build, release and cancellation signal DTOs" do
    common = {
      "contract_version" => 1,
      "event_id" => "019b9a80-0000-7000-8000-000000000020",
      "operation_id" => "019b9a80-0000-7000-8000-000000000021",
      "organization_id" => organization_id,
      "deployment_id" => deployment_id,
      "expected_version" => 2
    }
    build = common.merge(
      "message_type" => "build.completed",
      "build_id" => "019b9a80-0000-7000-8000-000000000022",
      "status" => "completed",
      "artifact_digest" => "sha256:#{"b" * 64}"
    )
    release = common.merge(
      "event_id" => "019b9a80-0000-7000-8000-000000000030",
      "message_type" => "release.ready",
      "status" => "ready",
      "revision_id" => "019b9a80-0000-7000-8000-000000000031",
      "artifact_digest" => "sha256:#{"b" * 64}"
    )
    cancellation = common.merge(
      "event_id" => "019b9a80-0000-7000-8000-000000000040",
      "message_type" => "deployment.cancel",
      "transition_id" => "019b9a80-0000-7000-8000-000000000041"
    )

    expect(described_class.build_workflow_signal(build)).to eq(build)
    expect(described_class.release_workflow_signal(release)).to eq(release)
    expect(described_class.cancellation_workflow_signal(cancellation)).to eq(cancellation)
  end
end

RSpec.describe LrailOrchestrator::Activities::AcknowledgeWorkflow do
  it "reuses the exact operation ID when an unknown result is retried" do
    calls = []
    control_plane = Object.new
    control_plane.define_singleton_method(:observe) do |operation|
      calls << operation
      raise LrailOrchestrator::ControlPlaneClient::Unavailable if calls.one?

      {
        "operation_id" => operation.fetch("operation_id"),
        "accepted" => true,
        "stale" => false,
        "current_version" => operation.fetch("expected_version"),
        "deployment_status" => "created"
      }
    end
    activity = described_class.new(control_plane)
    operation = {
      "contract_version" => 1,
      "operation_id" => "019b9a80-0000-7000-8000-000000000010",
      "organization_id" => "019b9a80-0000-7000-8000-000000000002",
      "deployment_id" => "019b9a80-0000-7000-8000-000000000003",
      "expected_version" => 0,
      "stage" => "workflow_accepted"
    }

    expect { activity.execute(operation) }
      .to raise_error(LrailOrchestrator::ControlPlaneClient::Unavailable)
    expect(activity.execute(operation)).to include("accepted" => true)
    expect(calls.map { |call| call.fetch("operation_id") }.uniq)
      .to eq([operation.fetch("operation_id")])
  end
end

RSpec.describe LrailOrchestrator::Activities::PrepareBuild do
  it "returns only the bounded build and revision identities" do
    input = {
      "contract_version" => 1,
      "event_id" => "019b9a80-0000-7000-8000-000000000010",
      "organization_id" => "019b9a80-0000-7000-8000-000000000002",
      "deployment_id" => "019b9a80-0000-7000-8000-000000000003",
      "service_id" => "019b9a80-0000-7000-8000-000000000011",
      "environment_id" => "019b9a80-0000-7000-8000-000000000012",
      "configuration_snapshot_id" => "019b9a80-0000-7000-8000-000000000013",
      "source_digest" => "sha256:#{"a" * 64}",
      "workload_type" => "web",
      "expected_version" => 0,
      "operation_id" => "019b9a80-0000-7000-8000-000000000010"
    }
    calls = []
    control_plane = Object.new
    control_plane.define_singleton_method(:prepare_build) do |value|
      calls << value
      {
        "contract_version" => 1,
        "operation_id" => value.fetch("operation_id"),
        "organization_id" => value.fetch("organization_id"),
        "deployment_id" => value.fetch("deployment_id"),
        "accepted" => true,
        "stale" => false,
        "current_version" => 3,
        "deployment_status" => "building",
        "build_id" => "019b9a80-0000-7000-8000-000000000005",
        "revision_id" => "019b9a80-0000-7000-8000-000000000006"
      }
    end

    result = described_class.new(control_plane).execute(input)

    expect(result).to include(
      "current_version" => 3,
      "deployment_status" => "building"
    )
    expect(JSON.generate(result)).not_to match(%r{https?://|password|secret|token})
    expect(calls).to contain_exactly(input)
  end
end

RSpec.describe LrailOrchestrator::Activities::RequestBuildCancellation do
  it "reuses the cancellation operation while returning a sanitized result" do
    signal = {
      "contract_version" => 1,
      "event_id" => "019b9a80-0000-7000-8000-000000000040",
      "operation_id" => "019b9a80-0000-7000-8000-000000000040",
      "organization_id" => "019b9a80-0000-7000-8000-000000000002",
      "deployment_id" => "019b9a80-0000-7000-8000-000000000003",
      "expected_version" => 4,
      "message_type" => "deployment.cancel",
      "transition_id" => "019b9a80-0000-7000-8000-000000000041"
    }
    control_plane = Object.new
    control_plane.define_singleton_method(:cancel_build) do |value|
      {
        "operation_id" => value.fetch("operation_id"),
        "accepted" => true,
        "stale" => false,
        "current_version" => value.fetch("expected_version"),
        "deployment_status" => "canceling"
      }
    end

    result = described_class.new(control_plane).execute(signal)

    expect(result).to include(
      "operation_id" => signal.fetch("operation_id"),
      "accepted" => true,
      "deployment_status" => "canceling"
    )
  end
end