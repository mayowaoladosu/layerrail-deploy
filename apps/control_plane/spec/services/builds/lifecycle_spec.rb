require "rails_helper"

RSpec.describe "Build lifecycle" do
  it "starts one idempotent build attempt and advances the deployment" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "build-start")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)

    first = Builds::Start.call(
      deployment:,
      idempotency_key: "build-attempt-1",
      expected_lock_version: deployment.lock_version
    )
    second = Builds::Start.call(
      deployment: deployment.reload,
      idempotency_key: "build-attempt-1",
      expected_lock_version: deployment.lock_version
    )

    expect(first.build).to have_attributes(attempt: 1, status: "running", idempotency_key: "build-attempt-1")
    expect(first.deployment.status).to eq("building")
    expect(second.build).to eq(first.build)
    expect(second.replayed).to be(true)
    expect(Build.count).to eq(1)
  end

  it "completes a build once and creates an immutable candidate revision" do
    context, project, environment, service, deployment = create_deployment_domain(sequence: "build-complete")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "build-complete-1",
      expected_lock_version: deployment.lock_version
    ).build

    result = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"a" * 64}",
      evidence: {
        "sbom_uri" => "object://evidence/sbom.json",
        "provenance_uri" => "object://evidence/provenance.json",
        "scan_status" => "passed"
      },
      region: "local",
      cell: "development"
    )

    expect(result.build).to have_attributes(status: "succeeded", artifact_digest: "sha256:#{"a" * 64}")
    expect(result.revision).to have_attributes(
      organization: project.organization,
      project:,
      service:,
      environment:,
      deployment:,
      build:,
      configuration_snapshot: deployment.configuration_snapshot,
      artifact_digest: "sha256:#{"a" * 64}",
      status: "candidate",
      region: "local",
      cell: "development"
    )
    expect(deployment.reload.status).to eq("scanning")
    expect do
      result.revision.update!(artifact_digest: "sha256:#{"b" * 64}")
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "rejects conflicting duplicate completion" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "build-conflict")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(deployment:, idempotency_key: "build-conflict-1", expected_lock_version: deployment.lock_version).build
    first = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"c" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    )
    replay = Builds::Complete.call(
      build: build.reload,
      artifact_digest: "sha256:#{"c" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    )

    expect(replay).to have_attributes(replayed: true, revision: first.revision)
    expect(Revision.where(build:).count).to eq(1)

    expect do
      Builds::Complete.call(
        build: build.reload,
        artifact_digest: "sha256:#{"d" * 64}",
        evidence: { "scan_status" => "passed" },
        region: "local",
        cell: "development"
      )
    end.to raise_error(Builds::Complete::CompletionConflict)
    expect do
      Builds::Complete.call(
        build: build.reload,
        artifact_digest: "sha256:#{"c" * 64}",
        evidence: { "scan_status" => "failed" },
        region: "local",
        cell: "development"
      )
    end.to raise_error(Builds::Complete::CompletionConflict)
  end

  it "creates a new numbered attempt after a retryable build failure" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "build-retry")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    first = Builds::Start.call(
      deployment:,
      idempotency_key: "build-retry-1",
      expected_lock_version: deployment.lock_version
    ).build
    failure = Builds::Fail.call(
      build: first,
      retryable: true,
      error: { "phase" => "building", "code" => "worker_lost", "message" => "Build worker was lost" }
    )

    second = Builds::Start.call(
      deployment: failure.deployment,
      idempotency_key: "build-retry-2",
      expected_lock_version: failure.deployment.lock_version
    ).build

    expect(first.reload).to have_attributes(status: "failed", attempt: 1)
    expect(second).to have_attributes(status: "running", attempt: 2)
    expect(failure.deployment.deployment_transitions.find_by!(cause: "build_retryable")).to have_attributes(
      from_status: "building",
      to_status: "preparing",
      cause: "build_retryable"
    )
  end

  it "fails the deployment when a build error is not retryable" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "build-terminal")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "build-terminal-1",
      expected_lock_version: deployment.lock_version
    ).build

    result = Builds::Fail.call(
      build:,
      retryable: false,
      error: { "phase" => "building", "code" => "build_command_failed", "message" => "Build failed" }
    )

    expect(result.deployment).to have_attributes(status: "failed", conclusion: "failed")
    expect do
      result.build.update!(evidence: { "error" => { "code" => "changed" }, "retryable" => false })
    end.to raise_error(ActiveRecord::RecordNotSaved)
  end

  it "completes an acknowledged build cancellation exactly once" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "build-cancel")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "build-cancel-1",
      expected_lock_version: deployment.lock_version
    ).build
    deployment = Deployments::Transition.call(
      deployment: deployment.reload,
      to: :canceling,
      actor: context.principal,
      cause: "cancellation_requested",
      expected_lock_version: deployment.lock_version
    ).deployment

    first = Builds::Cancel.call(build: build.reload)
    second = Builds::Cancel.call(build: build.reload)

    expect(first.build).to have_attributes(status: "canceled", finished_at: be_present)
    expect(first.deployment).to have_attributes(status: "canceled", conclusion: "canceled")
    expect(first.replayed).to be(false)
    expect(second.replayed).to be(true)
    expect(deployment.deployment_transitions.where(cause: "build_canceled").count).to eq(1)
  end
end
