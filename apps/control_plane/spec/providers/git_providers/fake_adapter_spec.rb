require "rails_helper"

RSpec.describe GitProviders::FakeAdapter do
  subject(:provider) { build_provider }

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

  def build_provider
    described_class.new(
      clock: -> { clock_time },
      webhook_secret: "webhook-secret",
      credential_seed: "credential-seed",
      installations: [
        GitProviders::Types::Installation.new(
          id: installation_id,
          account_id: "account-1",
          account_login: "layerrail",
          account_type: "organization",
          status: "active",
          permissions: { "contents" => "read", "metadata" => "read" }
        )
      ],
      repositories: {
        installation_id => [
          GitProviders::Types::Repository.new(
            id: repository_id,
            owner: "layerrail",
            name: "api",
            full_name: "layerrail/api",
            private: true,
            default_branch: "main",
            web_url: URI("https://git.example.test/layerrail/api")
          ),
          GitProviders::Types::Repository.new(
            id: "repository-2",
            owner: "layerrail",
            name: "web",
            full_name: "layerrail/web",
            private: false,
            default_branch: "main",
            web_url: URI("https://git.example.test/layerrail/web")
          )
        ]
      },
      branches: {
        repository_id => [
          GitProviders::Types::Branch.new(name: "main", sha: "bbbbbbbb", protected: true),
          GitProviders::Types::Branch.new(name: "develop", sha: "aaaaaaaa", protected: false)
        ]
      },
      commits: {
        [ repository_id, "main" ] => [
          GitProviders::Types::Commit.new(
            sha: "aaaaaaaa",
            message: "Initial commit",
            author_id: "provider-user-1",
            author_login: "mayowa",
            authored_at: clock_time - 1.hour,
            web_url: URI("https://git.example.test/layerrail/api/commit/aaaaaaaa")
          ),
          GitProviders::Types::Commit.new(
            sha: "bbbbbbbb",
            message: "Ship API",
            author_id: "provider-user-1",
            author_login: "mayowa",
            authored_at: clock_time,
            web_url: URI("https://git.example.test/layerrail/api/commit/bbbbbbbb")
          )
        ]
      },
      users_by_token: {
        "user-access-secret" => GitProviders::Types::ProviderUser.new(
          id: "provider-user-1",
          login: "mayowa",
          name: "Mayowa",
          email: "mayowa@example.test"
        )
      }
    )
  end

  def webhook_signature(body)
    digest = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)
    "sha256=#{digest}"
  end

  it_behaves_like "a Git provider adapter"
end
