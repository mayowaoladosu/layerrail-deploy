require "rails_helper"

RSpec.describe "Build, Revision and Alias constraints" do
  def create_ready_artifacts(sequence:)
    context, project, environment, service, deployment = create_deployment_domain(sequence:)
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "build-#{sequence}",
      expected_lock_version: deployment.lock_version
    ).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{Digest::SHA256.hexdigest(sequence)}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    revision = Revisions::MarkReady.call(
      revision:,
      readiness: { "status" => "passed" }
    ).revision
    alias_record = Aliases::Promote.call(
      context:,
      revision:,
      alias_type: :environment,
      name: environment.slug
    ).alias_record

    [ context, project, environment, service, deployment, build, revision, alias_record ]
  end

  it "uses application-generated UUIDv7 identifiers without database fallbacks" do
    _context, _project, _environment, _service, deployment, build, revision, alias_record =
      create_ready_artifacts(sequence: "artifact-uuid")
    records = [ build, revision, alias_record ]

    expect(records.map(&:id)).to all(match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/))
    expect([ Build, Revision, Alias ].map { |model| model.columns_hash.fetch("id").default_function }).to all(be_nil)
    expect(deployment.deployment_transitions.pluck(:correlation_id).uniq).to eq([ deployment.correlation_id ])
  end

  it "keeps terminal outputs, revision evidence and alias identity immutable" do
    _context, _project, _environment, _service, _deployment, build, revision, alias_record =
      create_ready_artifacts(sequence: "artifact-immutable")

    expect do
      build.update!(artifact_digest: "sha256:#{"f" * 64}")
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect do
      revision.update!(runtime_policy_snapshot: { "changed" => true })
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect do
      revision.update!(readiness: { "status" => "passed", "changed" => true })
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect do
      alias_record.update!(name: "changed")
    end.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "rejects cross-organization Build ownership in PostgreSQL" do
    _first_context, _first_project, _first_environment, _first_service, first_deployment =
      create_deployment_domain(sequence: "build-owner-first")
    second_context, = create_deployment_domain(sequence: "build-owner-second")
    timestamp = Time.current

    expect do
      Build.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: second_context.organization.id,
        deployment_id: first_deployment.id,
        attempt: 1,
        idempotency_key: "cross-organization-build",
        status: "running",
        artifact_digest: nil,
        evidence: {},
        started_at: timestamp,
        finished_at: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects cross-resource Alias pointers in PostgreSQL" do
    _first_context, first_project, first_environment, first_service, =
      create_deployment_domain(sequence: "alias-owner-first")
    _second_context, _second_project, _second_environment, _second_service, _second_deployment,
      _second_build, second_revision, = create_ready_artifacts(sequence: "alias-owner-second")
    timestamp = Time.current

    expect do
      Alias.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: first_project.organization_id,
        project_id: first_project.id,
        service_id: first_service.id,
        environment_id: first_environment.id,
        alias_type: "environment",
        name: "cross-resource",
        current_revision_id: second_revision.id,
        current_revision_status: "ready",
        previous_revision_id: nil,
        previous_revision_status: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects a candidate Revision Alias pointer in PostgreSQL" do
    context, project, environment, service, deployment =
      create_deployment_domain(sequence: "alias-candidate-constraint")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "alias-candidate-constraint",
      expected_lock_version: deployment.lock_version
    ).build
    revision = Builds::Complete.call(
      build:,
      artifact_digest: "sha256:#{"c" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    timestamp = Time.current

    expect do
      Alias.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: context.organization.id,
        project_id: project.id,
        service_id: service.id,
        environment_id: environment.id,
        alias_type: "environment",
        name: "candidate",
        current_revision_id: revision.id,
        current_revision_status: "ready",
        previous_revision_id: nil,
        previous_revision_status: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects a Revision whose artifact differs from its Build in PostgreSQL" do
    context, project, environment, service, deployment =
      create_deployment_domain(sequence: "revision-artifact-mismatch")
    timestamp = Time.current
    build = Build.create!(
      organization: context.organization,
      deployment:,
      attempt: 1,
      idempotency_key: "revision-artifact-mismatch",
      status: :succeeded,
      artifact_digest: "sha256:#{"a" * 64}",
      evidence: { "scan_status" => "passed" },
      started_at: timestamp,
      finished_at: timestamp
    )

    expect do
      Revision.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: context.organization.id,
        project_id: project.id,
        service_id: service.id,
        environment_id: environment.id,
        deployment_id: deployment.id,
        build_id: build.id,
        configuration_snapshot_id: deployment.configuration_snapshot_id,
        artifact_digest: "sha256:#{"b" * 64}",
        runtime_policy_snapshot: deployment.runtime_policy_snapshot,
        status: "candidate",
        readiness: {},
        region: "local",
        cell: "development",
        ready_at: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "rejects inconsistent Build terminal state in PostgreSQL" do
    context, _project, _environment, _service, deployment =
      create_deployment_domain(sequence: "build-state-constraint")
    timestamp = Time.current

    expect do
      Build.insert_all!([ {
        id: SecureRandom.uuid_v7,
        organization_id: context.organization.id,
        deployment_id: deployment.id,
        attempt: 1,
        idempotency_key: "inconsistent-build",
        status: "succeeded",
        artifact_digest: nil,
        evidence: {},
        started_at: timestamp,
        finished_at: nil,
        lock_version: 0,
        created_at: timestamp,
        updated_at: timestamp
      } ])
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
