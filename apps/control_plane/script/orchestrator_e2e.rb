require "json"

state_path = Pathname(ENV.fetch("ORCHESTRATOR_E2E_STATE_PATH"))
action = ARGV.fetch(0)

load_state = -> { JSON.parse(state_path.read) }

case action
when "recover-prior-leases"
  deployment_ids = Deployment
    .where("idempotency_key LIKE ?", "orchestrator-e2e-%")
    .pluck(:id)
  OutboxEvent.where(resource_id: deployment_ids, status: :delivering).find_each do |event|
    event.update!(locked_until: 1.second.ago)
  end
when "create"
  sequence = ENV.fetch("ORCHESTRATOR_E2E_RUN_ID")
  owner = User.create!(
    email: "orchestrator-e2e-#{sequence}@example.com",
    name: "Orchestrator E2E"
  )
  organization = Organizations::Create.call(
    principal: owner,
    name: "Orchestrator E2E #{sequence}"
  ).organization
  context = AuthorizationContext.build(principal: owner, organization:)
  project = Projects::Create.call(
    context:,
    name: "Temporal E2E #{sequence}",
    slug: "temporal-e2e-#{sequence}"
  ).project
  environment = project.environments.find_by!(kind: :production)
  service = Services::Create.call(
    context:,
    project:,
    name: "Web",
    workload_type: :web,
    source_type: :git,
    source_reference: "github:temporal-e2e",
    runtime_policy: { "readiness_path" => "/health" }
  ).service
  deployment = Deployments::Create.call(
    context:,
    service:,
    environment:,
    source: {
      "type" => "git",
      "reference" => "https://e2e-user:e2e-credential-secret@example.invalid/repository.git",
      "commit_sha" => Digest::SHA1.hexdigest(sequence),
      "repository_id" => "temporal-e2e"
    },
    idempotency_key: "orchestrator-e2e-#{sequence}",
    correlation_id: SecureRandom.uuid_v7,
    trigger: :manual
  ).deployment
  event = OutboxEvent.find_by!(
    resource_id: deployment.id,
    event_type: "deployment.requested.v1"
  )
  state = {
    "organization_id" => organization.id,
    "deployment_id" => deployment.id,
    "correlation_id" => deployment.correlation_id,
    "request_event_id" => event.id,
    "build_id" => SecureRandom.uuid_v7,
    "revision_id" => SecureRandom.uuid_v7,
    "artifact_digest" => "sha256:#{deployment.source_digest}"
  }
  state_path.dirname.mkpath
  state_path.write(JSON.generate(state))
when "expire-request-lease"
  state = load_state.call
  event = OutboxEvent.find(state.fetch("request_event_id"))
  raise "request event was not claimed" unless event.status == "delivering"

  event.update!(locked_until: 1.second.ago)
when "publish-build"
  state = load_state.call
  organization = Organization.find(state.fetch("organization_id"))
  OutboxEvents::Publish.call(
    organization:,
    resource_id: state.fetch("deployment_id"),
    event_type: "deployment.build.completed.v1",
    correlation_id: state.fetch("correlation_id"),
    idempotency_key: "orchestrator-e2e:#{state.fetch("deployment_id")}:build",
    producer: "build-controller",
    data: {
      "deployment_id" => state.fetch("deployment_id"),
      "operation_id" => SecureRandom.uuid_v7,
      "expected_version" => 1,
      "build_id" => state.fetch("build_id"),
      "artifact_digest" => state.fetch("artifact_digest"),
      "status" => "completed"
    }
  )
when "publish-stale-release"
  state = load_state.call
  organization = Organization.find(state.fetch("organization_id"))
  OutboxEvents::Publish.call(
    organization:,
    resource_id: state.fetch("deployment_id"),
    event_type: "deployment.runtime.ready.v1",
    correlation_id: state.fetch("correlation_id"),
    idempotency_key: "orchestrator-e2e:#{state.fetch("deployment_id")}:release:stale",
    producer: "runtime-controller",
    data: {
      "deployment_id" => state.fetch("deployment_id"),
      "operation_id" => SecureRandom.uuid_v7,
      "expected_version" => 0,
      "revision_id" => state.fetch("revision_id"),
      "artifact_digest" => state.fetch("artifact_digest")
    }
  )
when "publish-release"
  state = load_state.call
  organization = Organization.find(state.fetch("organization_id"))
  OutboxEvents::Publish.call(
    organization:,
    resource_id: state.fetch("deployment_id"),
    event_type: "deployment.runtime.ready.v1",
    correlation_id: state.fetch("correlation_id"),
    idempotency_key: "orchestrator-e2e:#{state.fetch("deployment_id")}:release:ready",
    producer: "runtime-controller",
    data: {
      "deployment_id" => state.fetch("deployment_id"),
      "operation_id" => SecureRandom.uuid_v7,
      "expected_version" => 1,
      "revision_id" => state.fetch("revision_id"),
      "artifact_digest" => state.fetch("artifact_digest")
    }
  )
when "publish-cancellation"
  state = load_state.call
  organization = Organization.find(state.fetch("organization_id"))
  OutboxEvents::Publish.call(
    organization:,
    resource_id: state.fetch("deployment_id"),
    event_type: "deployment.cancellation.requested.v1",
    correlation_id: state.fetch("correlation_id"),
    idempotency_key: "orchestrator-e2e:#{state.fetch("deployment_id")}:cancel",
    producer: "control-plane",
    data: {
      "deployment_id" => state.fetch("deployment_id"),
      "transition_id" => SecureRandom.uuid_v7,
      "expected_version" => 0
    }
  )
when "verify-authority"
  state = load_state.call
  deployment = Deployment.find(state.fetch("deployment_id"))
  events = OutboxEvent.where(resource_id: deployment.id).order(:created_at)
  workflow_events = events.where(event_type: [
    "deployment.requested.v1",
    "deployment.build.completed.v1",
    "deployment.runtime.ready.v1"
  ])
  raise "workflow events were not finalized" unless workflow_events.all?(&:published?)
  raise "workflow changed Rails deployment state" unless deployment.status == "created"
  raise "workflow created an authoritative revision" unless deployment.revisions.none?

  puts JSON.generate(
    "deployment_id" => deployment.id,
    "deployment_status" => deployment.status,
    "revision_count" => deployment.revisions.count,
    "workflow_event_count" => workflow_events.count,
    "published_workflow_event_count" => workflow_events.count(&:published?)
  )
when "verify-cancellation-authority"
  state = load_state.call
  deployment = Deployment.find(state.fetch("deployment_id"))
  workflow_events = OutboxEvent.where(
    resource_id: deployment.id,
    event_type: [
      "deployment.requested.v1",
      "deployment.cancellation.requested.v1"
    ]
  )
  raise "cancellation workflow events were not finalized" unless workflow_events.all?(&:published?)
  raise "cancellation workflow changed Rails state" unless deployment.status == "created"
  raise "cancellation workflow created a Revision" unless deployment.revisions.none?
when "show"
  puts state_path.read
else
  raise "unknown orchestrator E2E action"
end
