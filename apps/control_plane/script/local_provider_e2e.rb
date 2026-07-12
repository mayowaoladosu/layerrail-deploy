require "net/http"
require "json"

image_digest = ENV.fetch("SAMPLE_IMAGE_DIGEST")
raise "SAMPLE_IMAGE_DIGEST must be a SHA-256 digest" unless image_digest.match?(/\Asha256:[0-9a-f]{64}\z/)

user = User.find_by(email: ENV.fetch("E2E_EMAIL", "mayor@layerrail.local")) ||
  User.create!(email: ENV.fetch("E2E_EMAIL", "mayor@layerrail.local"), name: "Local Provider E2E")
organization = user.organizations.order(:created_at, :id).first ||
  Organizations::Create.call(principal: user, name: "Local Provider E2E").organization
context = AuthorizationContext.build(principal: user, organization:)
project = Project.find_by(organization:, slug: "local-provider-e2e") ||
  Projects::Create.call(context:, name: "Local Provider E2E", slug: "local-provider-e2e").project
service = project.services.find_by(name: "Sample Web") ||
  Services::Create.call(
    context:,
    project:,
    name: "Sample Web",
    workload_type: :web,
    source_type: :oci,
    source_reference: "lrail-local-sample:dev",
    runtime_policy: { "readiness_path" => "/health" }
  ).service
environment = project.environments.find_by!(kind: :production)
issued = Authentication::Sessions.issue(
  user:,
  kind: :api,
  ip: nil,
  user_agent: "local-provider-e2e"
)

api_request = lambda do |method:, path:, body: nil, key: nil|
  request_class = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post
  }.fetch(method)
  request = request_class.new(path)
  request["Host"] = "control.localhost"
  request["Authorization"] = "Bearer #{issued.token}"
  request["Content-Type"] = "application/json"
  request["Idempotency-Key"] = key if key
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(
    "127.0.0.1",
    3000,
    open_timeout: 2,
    read_timeout: 30
  ) { |http| http.request(request) }
  raise "#{method.upcase} #{path} failed: HTTP #{response.code}" unless response.code.to_i.between?(200, 299)
  response.body.present? ? JSON.parse(response.body) : {}
end

wait_for = lambda do |description, timeout: 420, &block|
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    result = block.call
    break result if result
    raise "Timed out waiting for #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.25
  end
end

create_deployment = lambda do |sequence|
  api_request.call(
    method: :post,
    path: "/v1/services/#{service.id}/deployments",
    key: "local-provider-e2e-#{sequence}-#{SecureRandom.uuid_v7}",
    body: {
      environment_id: environment.id,
      source: {
        type: "oci",
        reference: "lrail-local-sample:dev",
        digest: image_digest
      }
    }
  )
end

wait_ready = lambda do |deployment_id|
  wait_for.call("Deployment #{deployment_id} readiness") do
    deployment = Deployment.uncached { Deployment.find(deployment_id) }
    raise "Deployment #{deployment_id} failed" if deployment.status == "failed"
    deployment if deployment.status == "ready"
  end
end

promote = lambda do |revision_id, sequence|
  api_request.call(
    method: :post,
    path: "/v1/environments/#{environment.id}/promotions",
    key: "local-provider-e2e-promote-#{sequence}-#{SecureRandom.uuid_v7}",
    body: { revision_id: }
  )
end

rollback = lambda do |revision_id|
  api_request.call(
    method: :post,
    path: "/v1/environments/#{environment.id}/rollbacks",
    key: "local-provider-e2e-rollback-#{SecureRandom.uuid_v7}",
    body: { revision_id: }
  )
end

cancel = lambda do |deployment_id|
  api_request.call(
    method: :post,
    path: "/v1/deployments/#{deployment_id}/cancel",
    key: "local-provider-e2e-cancel-#{SecureRandom.uuid_v7}",
    body: { reason: "E2E cleanup after rollback" }
  )
end

route_body = lambda do |hostname|
  request = Net::HTTP::Get.new("/health")
  request["Host"] = hostname
  response = Net::HTTP.start(
    "traefik",
    80,
    open_timeout: 2,
    read_timeout: 2
  ) { |http| http.request(request) }
  response.code == "200" ? JSON.parse(response.body) : nil
rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error
  nil
end

begin
  first_response = create_deployment.call("first")
  first = wait_ready.call(first_response.fetch("id"))
  first_revision = first.revisions.where(status: "ready").sole
  raise "Provider resource evidence is missing" unless first_revision.readiness["resources"] == {
    "cpu_millicores" => 500,
    "memory_bytes" => 268435456
  }
  immutable = wait_for.call("first immutable route") do
    body = route_body.call(Routing::Hostnames.immutable(first))
    body if body&.fetch("deployment_id") == first.id
  end
  runtime_log = wait_for.call("signed runtime log retrieval") do
    result = LocalProvider::LogClient.fetch(
      organization_id: first.organization_id,
      deployment_id: first.id
    )
    result.entries.find { |entry| entry.message.include?("sample-web") } if result.status == :ok
  end
  promote.call(first_revision.id, "first")
  alias_record = Alias.find_by!(service:, environment:, alias_type: :environment)
  alias_hostname = Routing::Hostnames.environment(alias_record)
  wait_for.call("first environment route") do
    body = route_body.call(alias_hostname)
    body if body&.fetch("deployment_id") == first.id
  end

  second_response = create_deployment.call("second")
  second = wait_ready.call(second_response.fetch("id"))
  second_revision = second.revisions.where(status: "ready").sole
  wait_for.call("second immutable route") do
    body = route_body.call(Routing::Hostnames.immutable(second))
    body if body&.fetch("deployment_id") == second.id
  end
  promote.call(second_revision.id, "second")
  wait_for.call("second environment route") do
    body = route_body.call(alias_hostname)
    body if body&.fetch("deployment_id") == second.id
  end
  build_count = Build.where(deployment_id: [ first.id, second.id ]).count
  rollback.call(first_revision.id)
  rolled_back = wait_for.call("rolled-back environment route") do
    body = route_body.call(alias_hostname)
    body if body&.fetch("deployment_id") == first.id
  end
  raise "Rollback created a build" unless Build.where(deployment_id: [ first.id, second.id ]).count == build_count

  cancel.call(second.id)
  canceled = wait_for.call("second Deployment cancellation") do
    deployment = Deployment.uncached { Deployment.find(second.id) }
    raise "Second Deployment failed during cancellation" if deployment.status == "failed"
    deployment if deployment.status == "canceled"
  end
  cancellation_command = wait_for.call("published cancellation command") do
    event = OutboxEvent.uncached do
      OutboxEvent.find_by(
        resource_id: second.id,
        event_type: "deployment.cancellation.requested.v1"
      )
    end
    event if event&.status == "published"
  end
  wait_for.call("second immutable route removal") do
    route_body.call(Routing::Hostnames.immutable(second)).nil?
  end
  retained_logs = wait_for.call("retained runtime log state") do
    result = LocalProvider::LogClient.fetch(
      organization_id: second.organization_id,
      deployment_id: second.id
    )
    result if result.status == :ok && result.retained
  end
  serving = wait_for.call("rolled-back route after cancellation") do
    body = route_body.call(alias_hostname)
    body if body&.fetch("deployment_id") == first.id
  end
  alias_record.reload
  raise "Cancellation changed the serving Alias" unless alias_record.current_revision_id == first_revision.id
  begin
    Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    )
    raise "Canceled runtime became routable"
  rescue Aliases::Promote::RevisionNotReady
    nil
  end

  puts JSON.generate(
    status: "ok",
    first_deployment_id: first.id,
    second_deployment_id: second.id,
    first_revision_id: first_revision.id,
    second_revision_id: second_revision.id,
    immutable_url: first_response.fetch("preview_url"),
    alias_url: "http://#{alias_hostname}",
    immutable_response: immutable,
    runtime_log: {
      timestamp: runtime_log.timestamp.iso8601(6),
      stream: runtime_log.stream,
      message: runtime_log.message
    },
    rollback_response: rolled_back,
    post_cancellation_response: serving,
    canceled_status: canceled.status,
    cancellation_command_id: cancellation_command.id,
    cancellation_command_status: cancellation_command.status,
    retained_runtime_log_count: retained_logs.entries.length,
    build_count:
  )
ensure
  Authentication::Sessions.revoke(session: issued.session, reason: "e2e_complete")
end
