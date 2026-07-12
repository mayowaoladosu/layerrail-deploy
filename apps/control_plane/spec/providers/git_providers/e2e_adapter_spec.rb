require "rails_helper"

RSpec.describe GitProviders::E2eAdapter do
  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
  end

  around do |example|
    original = ENV["BUILD_CONTROLLER_E2E_PROVIDER_FILE"]
    example.run
  ensure
    ENV["BUILD_CONTROLLER_E2E_PROVIDER_FILE"] = original
  end

  it "issues bounded credentials only for the configured fake-private revision" do
    Dir.mktmpdir("git-provider-e2e") do |directory|
      path = Pathname(directory).join("provider.json")
      path.write(JSON.generate(
        installation_id: "installation-e2e",
        username: "fixture-user",
        secret: "fixture-secret-at-least-thirty-two-bytes",
        repositories: {
          "repository-e2e" => {
            clone_url: "http://git-fixture.lrail-system.svc.cluster.local:8080/sample.git",
            commit: "a" * 40
          }
        }
      ))
      ENV["BUILD_CONTROLLER_E2E_PROVIDER_FILE"] = path.to_s
      provider = GitProviders::Factory.github

      session = provider.open_session(installation_id: "installation-e2e").value
      result = session.clone_credentials(repository_id: "repository-e2e", revision: "a" * 40)

      expect(result).to be_success
      expect(result.value).to have_attributes(
        clone_url: URI("http://git-fixture.lrail-system.svc.cluster.local:8080/sample.git"),
        username: "fixture-user"
      )
      expect(result.value.secret).to eq("fixture-secret-at-least-thirty-two-bytes")
      expect(result.value.expires_at).to be_between(14.minutes.from_now, 16.minutes.from_now)
      expect(provider.inspect).not_to include(result.value.secret)
      expect(session.clone_credentials(repository_id: "repository-e2e", revision: "b" * 40)).to be_failure
    end
  end

  it "fails closed for another host or malformed configuration" do
    Dir.mktmpdir("git-provider-e2e") do |directory|
      path = Pathname(directory).join("provider.json")
      path.write(JSON.generate(
        installation_id: "installation-e2e",
        username: "fixture-user",
        secret: "fixture-secret-at-least-thirty-two-bytes",
        repositories: {
          "repository-e2e" => {
            clone_url: "http://attacker.example:8080/sample.git",
            commit: "a" * 40
          }
        }
      ))
      provider = described_class.new(path:)

      result = provider.open_session(installation_id: "installation-e2e")

      expect(result).to be_failure
      expect(result.error).to have_attributes(code: :provider_unavailable, retryable: true)
    end
  end

  it "rejects credentials embedded in a clone URL query or fragment" do
    expect do
      GitProviders::Types::CloneCredentials.new(
        clone_url: "https://git.example.test/repository.git?access_token=hidden",
        username: "x-access-token",
        secret: "separate-secret",
        expires_at: 10.minutes.from_now
      )
    end.to raise_error(ArgumentError, "clone URL is invalid")

    expect do
      GitProviders::Types::CloneCredentials.new(
        clone_url: "https://git.example.test/repository.git#hidden",
        username: "x-access-token",
        secret: "separate-secret",
        expires_at: 10.minutes.from_now
      )
    end.to raise_error(ArgumentError, "clone URL is invalid")
  end
end
