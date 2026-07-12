require "rails_helper"

require "json_schemer"
require "yaml"

RSpec.describe "Deployment logs API", type: :request do
  def api_schema(name)
    contract_path = Pathname(
      ENV.fetch("LRAIL_CONTRACTS_DIR", Rails.root.join("../../contracts"))
    ).join("openapi/v1/openapi.yaml")
    @api_document ||= JSONSchemer.openapi(YAML.safe_load_file(contract_path, aliases: true))
    @api_document.schema(name)
  end

  def provider_result(status: :ok, entries: [], truncated: false, retained: false)
    LocalProvider::LogClient::Result.new(status:, entries:, truncated:, retained:)
  end

  def get_logs(principal:, deployment:, params: {})
    get "/v1/deployments/#{deployment.id}/logs",
      params:,
      as: :json,
      env: { "lrail.authenticated_principal" => principal }
  end

  it "returns a schema-valid tail and advances an opaque cursor" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "api-logs")
    runtime = LocalProvider::LogClient::Entry.new(
      timestamp: Time.current + 1.second,
      stream: "runtime",
      message: "sample runtime ready"
    )
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(
      provider_result(entries: [ runtime ])
    )

    get_logs(principal: context.principal, deployment:, params: { limit: 100 })
    first = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(api_schema("LogCollection")).to be_valid(first)
    expect(first.fetch("data")).to include(
      include("stream" => "system", "message" => "Deployment request accepted."),
      include("stream" => "runtime", "message" => "sample runtime ready")
    )
    cursor = first.dig("page", "next_cursor")
    expect(cursor).to be_present

    get_logs(principal: context.principal, deployment:, params: { cursor:, limit: 100 })

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("data" => [], "page" => { "next_cursor" => cursor })
  end

  it "returns persisted events with a partial signal when the runtime is unavailable" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "api-partial-logs")
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(
      provider_result(status: :unavailable)
    )

    get_logs(principal: context.principal, deployment:)

    expect(response).to have_http_status(:ok)
    expect(response.headers.fetch("X-Lrail-Logs-Partial")).to eq("true")
    expect(response.parsed_body.fetch("data")).to include(
      include("stream" => "system", "message" => "Deployment request accepted.")
    )
  end

  it "validates pagination input" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "api-log-errors")
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(provider_result)

    get_logs(principal: context.principal, deployment:, params: { cursor: "invalid" })
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("details", "fields", "cursor")).to be_present

    get_logs(principal: context.principal, deployment:, params: { limit: 101 })
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("details", "fields", "limit")).to be_present
  end

  it "does not disclose or fetch logs across organizations" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "api-log-owned")
    foreign_context, = create_deployment_domain(sequence: "api-log-foreign")
    allow(LocalProvider::LogClient).to receive(:fetch).and_return(provider_result)

    get_logs(principal: foreign_context.principal, deployment:)
    expect(response).to have_http_status(:not_found)
    expect(LocalProvider::LogClient).not_to have_received(:fetch)
  end
end
