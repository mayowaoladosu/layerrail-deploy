require "rails_helper"

RSpec.describe GitProviders::GithubAdapter do
  subject(:provider) { build_provider }

  let(:clock_time) { Time.zone.parse("2026-07-11 20:00:00 UTC") }
  let(:installation_id) { "installation-1" }
  let(:repository_id) { "repository-1" }
  let(:private_key) { OpenSSL::PKey::RSA.generate(2048).to_pem }
  let(:unauthorized_repository) do
    GitProviders::Types::Repository.new(
      id: "repository-foreign",
      owner: "other",
      name: "private",
      full_name: "other/private",
      private: true,
      default_branch: "main",
      web_url: URI("https://git.example.test/other/private")
    )
  end

  class FixtureTransport
    attr_reader :requests

    def initialize(clock:)
      @clock = clock
      @requests = []
      @disconnected = false
    end

    def request(method:, path:, headers:, query: nil, body: nil)
      @requests << { method:, path:, headers:, query:, body: }

      case [ method, path ]
      when [ :get, "/app/installations/installation-1" ]
        installation_response
      when [ :delete, "/app/installations/installation-1" ]
        @disconnected = true
        response(204)
      when [ :post, "/app/installations/installation-1/access_tokens" ]
        response(201, "token" => "installation-access-secret", "expires_at" => (@clock + 15.minutes).iso8601)
      when [ :get, "/installation/repositories" ]
        response(
          200,
          "total_count" => 2,
          "repositories" => repositories.slice(page_offset(query), query.fetch(:per_page)) || []
        )
      when [ :get, "/repositories/repository-1" ]
        response(200, repositories.first)
      when [ :get, "/repositories/repository-foreign" ]
        response(404, "message" => "Not Found")
      when [ :get, "/repositories/repository-1/branches" ]
        response(200, branches)
      when [ :get, "/repositories/repository-1/commits" ]
        response(200, commits)
      when [ :get, "/repositories/repository-1/commits/bbbbbbbb" ]
        response(200, commits.first)
      when [ :get, "/repositories/repository-1/commits/unknown-revision" ]
        response(404, "message" => "Not Found")
      when [ :get, "/user" ]
        if headers.fetch("Authorization") == "Bearer user-access-secret"
          response(200, "id" => "provider-user-1", "login" => "mayowa", "name" => "Mayowa")
        else
          response(401, "message" => "Bad credentials")
        end
      when [ :get, "/user/emails" ]
        response(200, [ { "email" => "mayowa@example.test", "primary" => true, "verified" => true } ])
      else
        response(404, "message" => "Not Found")
      end
    end

    private

    def installation_response
      return response(404, "message" => "Not Found") if @disconnected

      response(
        200,
        "id" => "installation-1",
        "account" => { "id" => "account-1", "login" => "layerrail", "type" => "Organization" },
        "suspended_at" => nil,
        "permissions" => { "contents" => "read", "metadata" => "read" }
      )
    end

    def repositories
      [
        {
          "id" => "repository-1",
          "owner" => { "login" => "layerrail" },
          "name" => "api",
          "full_name" => "layerrail/api",
          "private" => true,
          "default_branch" => "main",
          "html_url" => "https://git.example.test/layerrail/api",
          "clone_url" => "https://git.example.test/layerrail/api.git"
        },
        {
          "id" => "repository-2",
          "owner" => { "login" => "layerrail" },
          "name" => "web",
          "full_name" => "layerrail/web",
          "private" => false,
          "default_branch" => "main",
          "html_url" => "https://git.example.test/layerrail/web",
          "clone_url" => "https://git.example.test/layerrail/web.git"
        }
      ]
    end

    def branches
      [
        { "name" => "main", "commit" => { "sha" => "bbbbbbbb" }, "protected" => true },
        { "name" => "develop", "commit" => { "sha" => "aaaaaaaa" }, "protected" => false }
      ]
    end

    def commits
      [
        {
          "sha" => "bbbbbbbb",
          "commit" => {
            "message" => "Ship API",
            "author" => { "date" => @clock.iso8601 }
          },
          "author" => { "id" => "provider-user-1", "login" => "mayowa" },
          "html_url" => "https://git.example.test/layerrail/api/commit/bbbbbbbb"
        },
        {
          "sha" => "aaaaaaaa",
          "commit" => {
            "message" => "Initial commit",
            "author" => { "date" => (@clock - 1.hour).iso8601 }
          },
          "author" => { "id" => "provider-user-1", "login" => "mayowa" },
          "html_url" => "https://git.example.test/layerrail/api/commit/aaaaaaaa"
        }
      ]
    end

    def page_offset(query)
      (query.fetch(:page, 1) - 1) * query.fetch(:per_page)
    end

    def response(status, body = {}, headers = {})
      GitProviders::Http::Response.new(status:, headers:, body:)
    end
  end

  def build_provider
    described_class.new(
      app_id: "4240374",
      app_slug: "layerrail-deploy",
      private_key:,
      webhook_secret: "webhook-secret",
      cursor_secret: "cursor-secret",
      transport: FixtureTransport.new(clock: clock_time),
      clock: -> { clock_time }
    )
  end

  def webhook_signature(body)
    digest = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)
    "sha256=#{digest}"
  end

  it "authenticates app requests with a short-lived RS256 JWT" do
    provider.installation(id: installation_id)
    transport = provider.instance_variable_get(:@transport)
    authorization = transport.requests.first.fetch(:headers).fetch("Authorization")
    token = authorization.delete_prefix("Bearer ")
    header_part, payload_part, signature_part = token.split(".")
    header, payload = [ header_part, payload_part ].map { |part| JSON.parse(Base64.urlsafe_decode64(part)) }
    verified = OpenSSL::PKey::RSA.new(private_key).public_key.verify(
      OpenSSL::Digest::SHA256.new,
      Base64.urlsafe_decode64(signature_part),
      "#{header_part}.#{payload_part}"
    )

    expect(header).to include("alg" => "RS256", "typ" => "JWT")
    expect(payload).to include("iss" => "4240374")
    expect(payload.fetch("exp") - payload.fetch("iat")).to be <= 600
    expect(verified).to be(true)
    expect(provider.inspect).not_to include(private_key)
  end

  it "does not serialize or inspect installation access tokens" do
    session = provider.open_session(installation_id:).value
    token = session.instance_variable_get(:@access_token)

    expect(token.to_h).to eq(expires_at: clock_time + 15.minutes)
    expect(token.inspect).not_to include("installation-access-secret")
    expect(session.inspect).not_to include("installation-access-secret")
  end

  it_behaves_like "a Git provider adapter"
end
