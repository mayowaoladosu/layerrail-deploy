module GitProviderFixtures
  def build_fake_git_provider(clock_time: Time.zone.parse("2026-07-11 20:00:00 UTC"))
    GitProviders::FakeAdapter.new(
      clock: -> { clock_time },
      webhook_secret: "webhook-secret",
      credential_seed: "credential-seed",
      installations: [
        GitProviders::Types::Installation.new(
          id: "installation-1",
          account_id: "account-1",
          account_login: "layerrail",
          account_type: "organization",
          status: "active",
          permissions: { "contents" => "read", "metadata" => "read" }
        )
      ],
      repositories: {
        "installation-1" => [
          GitProviders::Types::Repository.new(
            id: "repository-1",
            owner: "layerrail",
            name: "api",
            full_name: "layerrail/api",
            private: true,
            default_branch: "main",
            web_url: URI("https://git.example.test/layerrail/api")
          )
        ]
      },
      branches: {
        "repository-1" => [
          GitProviders::Types::Branch.new(name: "main", sha: "bbbbbbbb", protected: true)
        ]
      },
      commits: {
        [ "repository-1", "main" ] => [
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
      users_by_token: {}
    )
  end
end

RSpec.configure do |config|
  config.include GitProviderFixtures
end
