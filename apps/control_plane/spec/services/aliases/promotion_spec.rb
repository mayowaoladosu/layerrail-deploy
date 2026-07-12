require "rails_helper"

RSpec.describe "Alias promotion and rollback" do
  def candidate_revision(context:, service:, environment:, sequence:)
    deployment = Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "git",
        "reference" => "main",
        "commit_sha" => Digest::SHA1.hexdigest(sequence),
        "repository_id" => "repository-1"
      },
      idempotency_key: "deployment-#{sequence}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
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

    [ deployment, revision ]
  end

  def ready_revision(context:, service:, environment:, sequence:)
    deployment, revision = candidate_revision(context:, service:, environment:, sequence:)
    revision = Revisions::MarkReady.call(
      revision:,
      readiness: { "status" => "passed" }
    ).revision
    [ deployment.reload, revision ]
  end

  it "atomically promotes ready revisions and preserves the previous pointer" do
    context, _project, environment, service, = create_deployment_domain(sequence: "alias-domain")
    first_deployment, first_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "alias-first"
    )
    first = Aliases::Promote.call(
      context:,
      revision: first_revision,
      alias_type: :environment,
      name: environment.slug
    )
    second_deployment, second_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "alias-second"
    )

    second = Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    )

    expect(first.alias_record.current_revision).to eq(first_revision)
    expect(second.alias_record).to have_attributes(
      current_revision: second_revision,
      previous_revision: first_revision
    )
    expect(first_deployment.reload.status).to eq("superseded")
    expect(second_deployment.reload.status).to eq("promoted")
    routing_event = OutboxEvent.find_by!(
      resource_id: second.alias_record.id,
      event_type: "alias.routing.requested.v1",
      idempotency_key: "alias:#{second.alias_record.id}:version:#{second.alias_record.lock_version}:routing"
    )
    expect(routing_event.data).to include(
      "alias_id" => second.alias_record.id,
      "current_revision_id" => second_revision.id,
      "previous_revision_id" => first_revision.id,
      "current_deployment_id" => second_revision.deployment_id,
      "hostname" => Routing::Hostnames.environment(second.alias_record),
      "expected_version" => second.alias_record.lock_version
    )
  end

  it "rolls back to the previous ready revision without creating a build" do
    context, _project, environment, service, = create_deployment_domain(sequence: "rollback-domain")
    _first_deployment, first_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "rollback-first"
    )
    Aliases::Promote.call(context:, revision: first_revision, alias_type: :environment, name: environment.slug)
    _second_deployment, second_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "rollback-second"
    )
    alias_record = Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    ).alias_record
    build_count = Build.count

    result = Aliases::Rollback.call(
      context:,
      alias_record:,
      revision: first_revision,
      expected_lock_version: alias_record.lock_version
    )

    expect(result.alias_record.current_revision).to eq(first_revision)
    expect(result.alias_record.previous_revision).to eq(second_revision)
    expect(Build.count).to eq(build_count)
  end

  it "rejects candidate or cross-service revisions" do
    context, _project, environment, service, = create_deployment_domain(sequence: "alias-valid-domain")
    _candidate_deployment, candidate = candidate_revision(
      context:,
      service:,
      environment:,
      sequence: "alias-candidate"
    )
    _foreign_context, _foreign_project, _foreign_environment, _foreign_service, foreign_deployment =
      create_deployment_domain(sequence: "alias-foreign")
    foreign_deployment = advance_deployment(foreign_deployment, to: :queued)
    foreign_deployment = advance_deployment(foreign_deployment, to: :preparing)
    foreign_build = Builds::Start.call(
      deployment: foreign_deployment,
      idempotency_key: "build-alias-foreign",
      expected_lock_version: foreign_deployment.lock_version
    ).build
    foreign = Builds::Complete.call(
      build: foreign_build,
      artifact_digest: "sha256:#{"f" * 64}",
      evidence: { "scan_status" => "passed" },
      region: "local",
      cell: "development"
    ).revision
    foreign = Revisions::MarkReady.call(revision: foreign, readiness: { "status" => "passed" }).revision

    expect do
      Aliases::Promote.call(context:, revision: candidate, alias_type: :environment, name: environment.slug)
    end.to raise_error(Aliases::Promote::RevisionNotReady)
    expect do
      Aliases::Promote.call(context:, revision: foreign, alias_type: :environment, name: environment.slug)
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it "rejects a ready Revision after its non-serving runtime is canceled" do
    context, _project, environment, service, = create_deployment_domain(sequence: "alias-canceled")
    first_deployment, first_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "alias-canceled-first"
    )
    Aliases::Promote.call(context:, revision: first_revision, alias_type: :environment, name: environment.slug)
    second_deployment, second_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "alias-canceled-second"
    )
    Aliases::Promote.call(context:, revision: second_revision, alias_type: :environment, name: environment.slug)
    Aliases::Rollback.call(
      context:,
      alias_record: Alias.find_by!(service:, environment:, alias_type: :environment),
      revision: first_revision,
      expected_lock_version: Alias.find_by!(service:, environment:, alias_type: :environment).lock_version
    )
    canceled = Deployments::Cancel.call(
      context:,
      deployment: second_deployment.reload,
      expected_lock_version: second_deployment.reload.lock_version
    ).deployment
    advance_deployment(canceled, to: :canceled)

    expect do
      Aliases::Promote.call(
        context:,
        revision: second_revision,
        alias_type: :environment,
        name: environment.slug
      )
    end.to raise_error(Aliases::Promote::RevisionNotReady)
    expect(first_deployment.reload.status).to eq("promoted")
  end

  it "rejects a rollback command based on a stale alias version" do
    context, _project, environment, service, = create_deployment_domain(sequence: "rollback-stale-domain")
    _first_deployment, first_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "rollback-stale-first"
    )
    alias_record = Aliases::Promote.call(
      context:,
      revision: first_revision,
      alias_type: :environment,
      name: environment.slug
    ).alias_record
    stale_version = alias_record.lock_version
    _second_deployment, second_revision = ready_revision(
      context:,
      service:,
      environment:,
      sequence: "rollback-stale-second"
    )
    Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    )

    expect do
      Aliases::Rollback.call(
        context:,
        alias_record: alias_record.reload,
        revision: first_revision,
        expected_lock_version: stale_version
      )
    end.to raise_error(Aliases::Rollback::StaleAlias)
  end
end
