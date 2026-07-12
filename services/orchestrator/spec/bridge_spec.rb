# frozen_string_literal: true

RSpec.describe LrailOrchestrator::Bridge do
  Command = LrailOrchestrator::ControlPlaneClient::Command

  class FakeControlPlane
    attr_reader :finalizations

    def initialize(commands)
      @commands = commands
      @finalizations = []
    end

    def claim
      @commands.shift
    end

    def finalize(**value)
      @finalizations << value
      { "status" => value.fetch(:outcome) }
    end
  end

  class FakeHandle
    attr_reader :signals

    def initialize
      @signals = []
    end

    def signal(definition, value)
      @signals << [definition, value]
    end
  end

  class FakeTemporal
    attr_reader :starts, :handle

    def initialize
      @starts = []
      @handle = FakeHandle.new
    end

    def start_workflow(workflow, input, **options)
      @starts << [workflow, input, options]
      @handle
    end

    def workflow_handle(_id)
      @handle
    end
  end

  let(:event) do
    {
      "event_id" => "019b9a80-0000-7000-8000-000000000010",
      "event_type" => "deployment.requested.v1",
      "occurred_at" => "2026-07-11T22:00:00Z",
      "organization_id" => "019b9a80-0000-7000-8000-000000000002",
      "resource_id" => "019b9a80-0000-7000-8000-000000000003",
      "correlation_id" => "019b9a80-0000-7000-8000-000000000004",
      "idempotency_key" => "deployment:requested",
      "producer" => "control-plane",
      "schema_version" => 1,
      "data" => {
        "deployment_id" => "019b9a80-0000-7000-8000-000000000003",
        "service_id" => "019b9a80-0000-7000-8000-000000000011",
        "environment_id" => "019b9a80-0000-7000-8000-000000000012",
        "configuration_snapshot_id" => "019b9a80-0000-7000-8000-000000000013",
        "source_digest" => "a" * 64,
        "workload_type" => "web",
        "expected_version" => 0
      }
    }
  end

  it "starts duplicate delivery with one deterministic workflow identity" do
    commands = 2.times.map do |index|
      Command.new(
        event:,
        claim_token: "claim-#{index}",
        lease_expires_at: "2026-07-12T00:00:00Z"
      )
    end
    control_plane = FakeControlPlane.new(commands)
    temporal = FakeTemporal.new
    bridge = described_class.new(
      temporal:,
      control_plane:,
      task_queue: "lrail-deployments-v1",
      poll_interval: 0.1,
      logger: Logger.new(nil)
    )

    expect(bridge.run_once).to be(true)
    expect(bridge.run_once).to be(true)

    expect(temporal.starts.length).to eq(2)
    expect(temporal.starts.map { |start| start.last.fetch(:id) }.uniq)
      .to eq(["deployment/#{event.fetch("resource_id")}"])
    expect(temporal.starts.map { |start| start[1] }.uniq.length).to eq(1)
    expect(temporal.starts.first.last).to include(
      id_reuse_policy: Temporalio::WorkflowIDReusePolicy::REJECT_DUPLICATE,
      id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::USE_EXISTING
    )
    expect(control_plane.finalizations.map { |value| value.fetch(:outcome) })
      .to eq(%w[published published])
  end

  it "rejects an event that cannot enter workflow history" do
    invalid = Marshal.load(Marshal.dump(event))
    invalid["data"]["source_digest"] = "latest"
    control_plane = FakeControlPlane.new([
      Command.new(
        event: invalid,
        claim_token: "claim-invalid",
        lease_expires_at: "2026-07-12T00:00:00Z"
      )
    ])
    bridge = described_class.new(
      temporal: FakeTemporal.new,
      control_plane:,
      task_queue: "lrail-deployments-v1",
      poll_interval: 0.1,
      logger: Logger.new(nil)
    )

    bridge.run_once

    expect(control_plane.finalizations).to contain_exactly(
      hash_including(outcome: "rejected", safe_error: "workflow_contract_invalid")
    )
  end
end
