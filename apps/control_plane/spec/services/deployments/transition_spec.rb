require "rails_helper"

RSpec.describe Deployments::Transition do
  def create_deployment
    owner = User.create!(email: "transition-owner@example.com", name: "Transition")
    organization = Organizations::Create.call(principal: owner, name: "Transition Organization").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Transition Project", slug: "transition-project").project
    environment = project.environments.find_by!(kind: :production)
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:repository-1"
    ).service
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: { "type" => "git", "reference" => "main", "commit_sha" => "e" * 40, "repository_id" => "repository-1" },
      idempotency_key: "transition-deployment",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment

    [ context, deployment ]
  end

  it "records every allowed transition with optimistic concurrency" do
    context, deployment = create_deployment

    %i[queued preparing building scanning deploying verifying ready promoted].each do |status|
      result = described_class.call(
        deployment:,
        to: status,
        actor: context.principal,
        cause: "test",
        expected_lock_version: deployment.lock_version
      )
      deployment = result.deployment
    end

    expect(deployment).to have_attributes(status: "promoted", conclusion: "succeeded")
    expect(deployment.deployment_transitions.order(:sequence).pluck(:sequence)).to eq((1..9).to_a)
  end

  it "rejects invalid and stale transitions without appending history" do
    context, deployment = create_deployment
    transition_count = deployment.deployment_transitions.count

    expect do
      described_class.call(
        deployment:,
        to: :ready,
        actor: context.principal,
        cause: "skip",
        expected_lock_version: deployment.lock_version
      )
    end.to raise_error(Deployments::Transition::InvalidTransition)
    expect do
      described_class.call(
        deployment:,
        to: :queued,
        actor: context.principal,
        cause: "stale",
        expected_lock_version: 99
      )
    end.to raise_error(Deployments::Transition::StaleTransition)

    expect(deployment.deployment_transitions.count).to eq(transition_count)
  end

  it "records structured terminal failures separately from status" do
    _context, deployment = create_deployment

    result = described_class.call(
      deployment:,
      to: :failed,
      actor: nil,
      cause: "build_failed",
      expected_lock_version: deployment.lock_version,
      error: {
        "phase" => "building",
        "code" => "build_command_failed",
        "message" => "Build command failed",
        "diagnostic_reference" => "diag-123"
      }
    )

    expect(result.deployment).to have_attributes(status: "failed", conclusion: "failed")
    expect(result.transition.error).to eq(
      "phase" => "building",
      "code" => "build_command_failed",
      "message" => "Build command failed",
      "diagnostic_reference" => "diag-123"
    )
  end
end
