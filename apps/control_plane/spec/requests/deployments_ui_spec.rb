require "rails_helper"

RSpec.describe "Deployment UI", type: :request do
  def sign_in(user)
    issued = Authentication::Sessions.issue(user:, kind: :web, ip: nil, user_agent: "deployment-ui-spec")
    cookies[Authentication::Middleware::COOKIE_NAME] = issued.token
  end

  def provider_result(status: :ok, entries: [], truncated: false, retained: false)
    LocalProvider::LogClient::Result.new(status:, entries:, truncated:, retained:)
  end

  def ready_deployment(deployment, context:, sequence:)
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing, actor: context.principal)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "ui-build-#{sequence}",
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
      readiness: {
        "status" => "passed",
        "checked_at" => Time.current.iso8601(6),
        "resources" => {
          "cpu_millicores" => 500,
          "memory_bytes" => 268435456
        }
      }
    ).revision
    [ deployment.reload, revision ]
  end

  def another_deployment(context:, service:, environment:, sequence:)
    Deployments::Create.call(
      context:,
      service:,
      environment:,
      source: {
        "type" => "git",
        "reference" => "main",
        "commit_sha" => Digest::SHA1.hexdigest(sequence),
        "repository_id" => "repository-1"
      },
      idempotency_key: "ui-deployment-#{sequence}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :manual
    ).deployment
  end

  before do
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(
      provider_result(status: :not_found)
    )
  end

  it "requires a web session and renders tenant-scoped accessible history and detail" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "ui-view")
    foreign_context, = create_deployment_domain(sequence: "ui-view-foreign")

    get organization_deployments_path(context.organization)
    expect(response).to redirect_to(auth_login_path)

    sign_in(context.principal)
    get organization_deployments_path(context.organization)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Deployment history", deployment.service.name)
    expect(response.body).to include("<main id=\"main-content\"")

    get organization_deployment_path(context.organization, deployment)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Persisted status",
      "Generated URLs",
      "Current and previous",
      "Live logs",
      "Status timeline",
      "aria-busy=\"false\"",
      "role=\"log\"",
      "Search logs",
      "<dt>Actor</dt>"
    )
    expect(response.body).to include("data-turbo-confirm")

    get download_logs_organization_deployment_path(context.organization, deployment)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/plain")
    expect(response.headers.fetch("Content-Disposition")).to include("attachment")
    expect(response.body).to include("SYSTEM INFO Deployment request accepted.")

    get organization_deployment_path(foreign_context.organization, deployment)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(deployment.source_snapshot.fetch("commit_sha"))
  end

  it "lets members inspect but not mutate deployment state" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "ui-member")
    deployment, _revision = ready_deployment(deployment, context:, sequence: "ui-member")
    member = User.create!(email: "ui-member@example.com", name: "UI Member")
    Membership.create!(user: member, organization: context.organization, role: :member)
    sign_in(member)

    get organization_deployment_path(context.organization, deployment)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Members can inspect this deployment")
    expect(response.body).not_to include("Promote to Production")

    post promote_organization_deployment_path(context.organization, deployment)
    expect(response).to have_http_status(:forbidden)
    expect(Alias.where(service: deployment.service)).not_to exist
  end

  it "returns no live markup when unchanged and replaces it after persisted progress" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "ui-live")
    sign_in(context.principal)
    get organization_deployment_path(context.organization, deployment)
    version = response.body.match(/data-live-status-version-value="([0-9a-f]+)"/).captures.first
    live_path = live_organization_deployment_path(context.organization, deployment, format: :turbo_stream)
    headers = {
      "Accept" => "text/vnd.turbo-stream.html",
      "X-Lrail-Live-Version" => version
    }

    get live_path, headers: headers
    expect(response).to have_http_status(:not_modified)

    advance_deployment(deployment, to: :queued, actor: context.principal)
    get live_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include("turbo-stream action=\"replace\"", "Queued")
  end

  it "renders retained runtime output after a deployment stops" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "ui-retained")
    deployment = advance_deployment(deployment, to: :canceling, actor: context.principal)
    deployment = advance_deployment(deployment, to: :canceled)
    retained_entry = LocalProvider::LogClient::Entry.new(
      timestamp: Time.current,
      stream: "runtime",
      message: "final runtime line"
    )
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(
      provider_result(entries: [ retained_entry ], retained: true)
    )
    sign_in(context.principal)

    get organization_deployment_path(context.organization, deployment)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Retained runtime logs",
      "The runtime has stopped",
      "final runtime line",
      "No longer routed"
    )
    expect(response.body).not_to include("Promote to Production")

    post promote_organization_deployment_path(context.organization, deployment)
    expect(response).to redirect_to(organization_deployment_path(context.organization, deployment))
    expect(Alias.where(service: deployment.service)).not_to exist
  end

  it "promotes, rolls back without a Build, cancels the non-serving runtime and deduplicates redeploy" do
    context, _project, environment, service, first = create_deployment_domain(sequence: "ui-actions")
    first, first_revision = ready_deployment(first, context:, sequence: "ui-actions-first")
    sign_in(context.principal)

    get organization_deployment_path(context.organization, first)
    expect(response.body).to include(
      "Promote to Production",
      "Cancel deployment",
      "Redeploy",
      "0.5 vCPU · 256 MiB memory"
    )
    expect(response.body).not_to include("value=\"Roll back\"")

    post promote_organization_deployment_path(context.organization, first)
    expect(response).to redirect_to(organization_deployment_path(context.organization, first))
    alias_record = Alias.find_by!(service:, environment:, alias_type: :environment)
    expect(alias_record.current_revision).to eq(first_revision)
    get organization_deployment_path(context.organization, first)
    expect(response.body).not_to include("Promote to Production", "Cancel deployment")

    second = another_deployment(context:, service:, environment:, sequence: "ui-actions-second")
    second, second_revision = ready_deployment(second, context:, sequence: "ui-actions-second")
    Aliases::Promote.call(
      context:,
      revision: second_revision,
      alias_type: :environment,
      name: environment.slug
    )
    alias_record.reload
    build_count = Build.count

    post rollback_organization_deployment_path(context.organization, second), params: {
      revision_id: first_revision.id,
      expected_lock_version: alias_record.lock_version
    }

    expect(response).to redirect_to(organization_deployment_path(context.organization, second))
    expect(alias_record.reload.current_revision).to eq(first_revision)
    expect(Build.count).to eq(build_count)

    post cancel_organization_deployment_path(context.organization, second)
    expect(response).to redirect_to(organization_deployment_path(context.organization, second))
    expect(second.reload.status).to eq("canceling")
    expect(OutboxEvent.where(
      resource_id: second.id,
      event_type: "deployment.cancellation.requested.v1"
    )).to exist
    advance_deployment(second.reload, to: :canceled)
    get organization_deployment_path(context.organization, first)
    expect(response.body).to include("Canceled · history only")
    expect(response.body).not_to include("value=\"Roll back\"")

    operation_id = SecureRandom.uuid_v7
    expect do
      2.times do
        post redeploy_organization_deployment_path(context.organization, first), params: { operation_id: }
      end
    end.to change(Deployment, :count).by(1)
    expect(response).to redirect_to(
      organization_deployment_path(context.organization, Deployment.order(:created_at, :id).last)
    )
  end
end
