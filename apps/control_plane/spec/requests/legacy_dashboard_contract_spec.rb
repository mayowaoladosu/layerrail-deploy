require "rails_helper"

RSpec.describe "Legacy Devpush dashboard contract", type: :request do
  before do
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(
      LocalProvider::LogClient::Result.new(
        status: :not_found,
        entries: [],
        truncated: false,
        retained: false
      )
    )
  end

  it "uses the original Devpush assets and authenticated shell instead of a parallel dashboard" do
    context, project, _environment, _service, _deployment = create_deployment_domain(sequence: "legacy-shell")
    sign_in_with_rodauth(context.principal)

    get root_path

    expect(response).to redirect_to(team_path(context.organization.slug))

    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "legacy-assets/styles.css",
      "legacy-assets/basecoat.min.js",
      "legacy-assets/alpine.min.js",
      "legacy-assets/htmx.min.js",
      "sticky top-0 bg-background z-20 border-b px-8",
      "container max-w-screen-xl mx-auto p-8 space-y-6",
      "class=\"toaster\"",
      "Recent projects",
      project.name
    )
    expect(response.body).not_to include(
      "Control plane",
      "Authenticated session",
      "welcome-card",
      "app-brand-mark"
    )
  end

  it "keeps the legacy team/project/deployment hierarchy and visual vocabulary" do
    context, project, _environment, _service, deployment = create_deployment_domain(sequence: "legacy-routes")
    sign_in_with_rodauth(context.principal)

    get project_path(context.organization.slug, project.slug)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Environments", "Latest deployments", deployment.id.first(7))

    get project_deployments_path(context.organization.slug, project.slug)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("All statuses", "All dates", "All branches")
    expect(response.body).not_to include("Release history", "page-heading")

    get project_deployment_path(context.organization.slug, project.slug, deployment)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "deployment-page-header",
      "deployment-logs",
      "h-[500px]",
      "Logs",
      "Deployment URL",
      "Search logs",
      deployment.id.first(7)
    )
    expect(response.body).not_to include("status-hero", "surface-card", "app-shell")
  end

  it "fails closed when canonical team and project slugs cross organizations" do
    context, project, _environment, _service, deployment = create_deployment_domain(sequence: "legacy-owner")
    foreign_context, foreign_project, _foreign_environment, _foreign_service, foreign_deployment =
      create_deployment_domain(sequence: "legacy-foreign")
    sign_in_with_rodauth(context.principal)

    get team_path(foreign_context.organization.slug)
    expect(response).to have_http_status(:not_found)

    get project_path(context.organization.slug, foreign_project.slug)
    expect(response).to have_http_status(:not_found)

    get project_deployment_path(context.organization.slug, project.slug, foreign_deployment)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(foreign_deployment.source_snapshot.fetch("commit_sha"))

    get project_deployment_path(context.organization.slug, project.slug, deployment)
    expect(response).to have_http_status(:ok)
  end

  it "serves the original compiled asset bytes rather than a restyled copy" do
    root = Pathname(ENV.fetch("LEGACY_UI_ROOT", Rails.root.join("../../app").expand_path.to_s)).join("assets")
    expected_types = {
      "styles.css" => "text/css",
      "basecoat.min.js" => "application/javascript",
      "alpine.min.js" => "application/javascript",
      "htmx.min.js" => "application/javascript",
      "htmx-sse.min.js" => "application/javascript",
      "favicon.svg" => "image/svg+xml",
      "apple-touch-icon.png" => "image/png",
      "social.png" => "image/png"
    }

    expected_types.each do |filename, media_type|
      get legacy_asset_path(filename)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(media_type)
      expect(Digest::SHA256.hexdigest(response.body)).to eq(
        Digest::SHA256.file(root.join(filename)).hexdigest
      )
    end
  end
end
