# frozen_string_literal: true

require "spec_helper"

RSpec.describe LrailOrchestrator::Workflows::DeploymentWorkflow do
  let(:operation_id) { "019b9a80-0000-7000-8000-000000000010" }
  let(:build_id) { "019b9a80-0000-7000-8000-000000000005" }
  let(:revision_id) { "019b9a80-0000-7000-8000-000000000006" }
  let(:artifact_digest) { "sha256:" + ("a" * 64) }
  let(:workflow) do
    described_class.allocate.tap do |value|
      value.instance_variable_set(:@input, { "operation_id" => operation_id })
      value.instance_variable_set(:@build_id, build_id)
      value.instance_variable_set(:@revision_id, revision_id)
      value.instance_variable_set(:@artifact_digest, artifact_digest)
    end
  end

  it "binds Build signals to the prepared operation and Build" do
    valid = {
      "operation_id" => operation_id,
      "build_id" => build_id
    }

    expect(workflow.send(:signal_identity_matches?, :build, valid)).to be(true)
    expect(
      workflow.send(
        :signal_identity_matches?,
        :build,
        valid.merge("operation_id" => "019b9a80-0000-7000-8000-000000000011")
      )
    ).to be(false)
    expect(
      workflow.send(
        :signal_identity_matches?,
        :build,
        valid.merge("build_id" => "019b9a80-0000-7000-8000-000000000012")
      )
    ).to be(false)
  end

  it "binds ready signals to the prepared Revision and completed digest" do
    valid = {
      "status" => "ready",
      "revision_id" => revision_id,
      "artifact_digest" => artifact_digest
    }

    expect(workflow.send(:signal_identity_matches?, :release, valid)).to be(true)
    expect(
      workflow.send(
        :signal_identity_matches?,
        :release,
        valid.merge("revision_id" => "019b9a80-0000-7000-8000-000000000013")
      )
    ).to be(false)
    expect(
      workflow.send(
        :signal_identity_matches?,
        :release,
        valid.merge("artifact_digest" => "sha256:" + ("b" * 64))
      )
    ).to be(false)
  end
end
