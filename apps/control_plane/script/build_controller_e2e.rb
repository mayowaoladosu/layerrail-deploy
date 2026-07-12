require "json"

state_path = Pathname(ENV.fetch("BUILD_CONTROLLER_E2E_STATE_PATH", "/rails/tmp/build-controller-e2e-state.json"))
provider_path = Pathname(ENV.fetch("BUILD_CONTROLLER_E2E_PROVIDER_FILE"))
action = ARGV.fetch(0)
scenario = ARGV[1]

load_state = -> { JSON.parse(state_path.read) }
write_state = lambda do |value|
  state_path.dirname.mkpath
  temporary = state_path.sub_ext(".tmp")
  temporary.write(JSON.generate(value))
  temporary.chmod(0600)
  temporary.rename(state_path)
end

snapshot = lambda do |deployment|
  deployment.reload
  build = deployment.builds.order(:attempt).last
  revision = build&.revision
  command = build && OutboxEvent.find_by(resource_id: build.id, event_type: "build.requested.v1")
  {
    "deployment_id" => deployment.id,
    "deployment_status" => deployment.status,
    "deployment_version" => deployment.lock_version,
    "build_id" => build&.id,
    "build_status" => build&.status,
    "artifact_digest" => build&.artifact_digest,
    "evidence" => build&.evidence || {},
    "revision_id" => revision&.id,
    "revision_status" => revision&.status,
    "revision_count" => deployment.revisions.count,
    "command_id" => command&.id,
    "command_status" => command&.status,
    "command_attempts" => command&.attempt_count,
    "job_name" => build && "build-#{build.id.delete("-").first(24)}",
    "secret_name" => build && "build-credentials-#{build.id.delete("-").first(16)}"
  }
end

case action
when "setup"
  run_id = ENV.fetch("BUILD_CONTROLLER_E2E_RUN_ID")
  provider = JSON.parse(provider_path.read)
  raise "provider fixture is invalid" unless provider["repositories"].is_a?(Hash)

  owner = User.create!(
    email: "build-controller-e2e-#{run_id}@example.com",
    name: "Build Controller E2E"
  )
  organization = Organizations::Create.call(
    principal: owner,
    name: "Build Controller E2E #{run_id}"
  ).organization
  context = AuthorizationContext.build(principal: owner, organization:)
  project = Projects::Create.call(
    context:,
    name: "Build Controller E2E #{run_id}",
    slug: "build-controller-e2e-#{run_id}"
  ).project
  installation = GitInstallation.create!(
    organization:,
    provider: :github,
    provider_installation_id: provider.fetch("installation_id"),
    account_id: "e2e-account-#{run_id}",
    account_login: "layerrail-e2e",
    account_type: "organization",
    status: :active,
    permissions: { "contents" => "read" }
  )
  services = provider.fetch("repositories").sort.to_h do |name, repository|
    workload_type = name.include?("static") ? :static : :web
    service = Services::Create.call(
      context:,
      project:,
      name: name.tr("-", " ").titleize,
      workload_type:,
      source_type: :git,
      source_reference: "github:#{name}",
      runtime_policy: workload_type == :web ? { "readiness_path" => "/" } : {}
    ).service
    RepositoryConnection.create!(
      organization:,
      git_installation: installation,
      project:,
      service:,
      provider_repository_id: name,
      owner: "layerrail-e2e",
      name:,
      full_name: "layerrail-e2e/#{name}",
      private: true,
      default_branch: "main",
      status: :active
    )
    [ name, {
      "service_id" => service.id,
      "workload_type" => workload_type.to_s,
      "commit" => repository.fetch("commit")
    } ]
  end
  state = {
    "run_id" => run_id,
    "owner_id" => owner.id,
    "organization_id" => organization.id,
    "project_id" => project.id,
    "installation_id" => installation.id,
    "services" => services,
    "deployments" => {}
  }
  write_state.call(state)
  puts JSON.generate(state.except("services").merge("service_count" => services.size))
when "deploy"
  raise "scenario is required" unless scenario

  state = load_state.call
  service_state = state.fetch("services").fetch(scenario)
  owner = User.find(state.fetch("owner_id"))
  organization = Organization.find(state.fetch("organization_id"))
  context = AuthorizationContext.build(principal: owner, organization:)
  project = Project.find(state.fetch("project_id"))
  service = Service.find(service_state.fetch("service_id"))
  environment = project.environments.find_by!(kind: :production)
  result = Deployments::Create.call(
    context:,
    service:,
    environment:,
    source: {
      "type" => "git",
      "reference" => "main",
      "commit_sha" => service_state.fetch("commit"),
      "repository_id" => scenario
    },
    idempotency_key: "build-controller-e2e-#{state.fetch('run_id')}-#{scenario}",
    correlation_id: SecureRandom.uuid_v7,
    trigger: :manual
  )
  state["deployments"][scenario] = result.deployment.id
  write_state.call(state)
  puts JSON.generate(snapshot.call(result.deployment).merge("replayed" => result.replayed))
when "cancel"
  raise "scenario is required" unless scenario

  state = load_state.call
  owner = User.find(state.fetch("owner_id"))
  organization = Organization.find(state.fetch("organization_id"))
  context = AuthorizationContext.build(principal: owner, organization:)
  deployment = Deployment.find(state.fetch("deployments").fetch(scenario))
  result = Deployments::Cancel.call(
    context:,
    deployment:,
    expected_lock_version: deployment.lock_version
  )
  puts JSON.generate(snapshot.call(result.deployment))
when "wait"
  raise "scenario is required" unless scenario

  state = load_state.call
  deployment = Deployment.find(state.fetch("deployments").fetch(scenario))
  expected = ENV.fetch("BUILD_CONTROLLER_E2E_EXPECT", "succeeded")
  timeout = Integer(ENV.fetch("BUILD_CONTROLLER_E2E_TIMEOUT", "900"), 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = snapshot.call(deployment)
    done = case expected
    when "running"
      value["build_status"] == "running" && value["deployment_status"] == "building"
    when "succeeded"
      value["build_status"] == "succeeded" && value["revision_status"] == "candidate"
    when "failed"
      value["build_status"] == "failed" && value["deployment_status"] == "failed"
    when "canceled"
      value["build_status"] == "canceled" && value["deployment_status"] == "canceled"
    else
      raise "unknown expected state"
    end
    if done
      puts JSON.generate(value)
      break
    end
    if expected == "succeeded" && value["deployment_status"].in?(%w[failed canceled])
      raise "build terminated as #{value.fetch('deployment_status')}: #{JSON.generate(value)}"
    end
    raise "timed out: #{JSON.generate(value)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.5
  end
when "show"
  state = load_state.call
  if scenario
    puts JSON.generate(snapshot.call(Deployment.find(state.fetch("deployments").fetch(scenario))))
  else
    puts JSON.generate(state.fetch("deployments").transform_values do |deployment_id|
      snapshot.call(Deployment.find(deployment_id))
    end)
  end
when "duplicate-command"
  raise "scenario is required" unless scenario

  state = load_state.call
  deployment = Deployment.find(state.fetch("deployments").fetch(scenario))
  build = deployment.builds.sole
  original = OutboxEvent.find_by!(resource_id: build.id, event_type: "build.requested.v1")
  duplicate = OutboxEvents::Publish.call(
    organization: deployment.organization,
    resource_id: build.id,
    event_type: "build.requested.v1",
    correlation_id: deployment.correlation_id,
    idempotency_key: "build:#{build.id}:requested:e2e-duplicate",
    producer: "control-plane",
    data: original.data
  ).event
  puts JSON.generate(snapshot.call(deployment).merge("duplicate_command_id" => duplicate.id))
when "wait-commands"
  raise "scenario is required" unless scenario

  state = load_state.call
  deployment = Deployment.find(state.fetch("deployments").fetch(scenario))
  build = deployment.builds.sole
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
  loop do
    commands = OutboxEvent.where(resource_id: build.id, event_type: "build.requested.v1").order(:created_at, :id)
    if commands.size >= 2 && commands.all?(&:published?)
      puts JSON.generate(
        "build_id" => build.id,
        "build_count" => deployment.builds.count,
        "revision_count" => deployment.revisions.count,
        "command_ids" => commands.pluck(:id),
        "command_attempts" => commands.pluck(:attempt_count)
      )
      break
    end
    raise "duplicate command was not finalized" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.25
  end
when "verify-secret-absence"
  state = load_state.call
  provider = JSON.parse(provider_path.read)
  forbidden = [ provider.fetch("secret") ] + provider.fetch("repositories").values.map do |repository|
    repository.fetch("clone_url")
  end
  deployment_ids = state.fetch("deployments").values
  retained = []
  retained.concat(Deployment.where(id: deployment_ids).pluck(:source_snapshot, :runtime_policy_snapshot, :build_settings_snapshot))
  retained.concat(Build.where(deployment_id: deployment_ids).pluck(:evidence))
  retained.concat(DeploymentTransition.where(deployment_id: deployment_ids).pluck(:error))
  retained.concat(OutboxEvent.where(resource_id: deployment_ids + Build.where(deployment_id: deployment_ids).pluck(:id)).pluck(:data))
  body = JSON.generate(retained)
  raise "clone credential leaked into Rails state" if forbidden.any? { |value| body.include?(value) }

  puts JSON.generate("status" => "ok", "checked_records" => retained.size)
else
  raise "unknown build-controller E2E action"
end
