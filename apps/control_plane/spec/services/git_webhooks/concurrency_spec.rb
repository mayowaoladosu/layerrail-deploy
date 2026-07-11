require "rails_helper"

RSpec.describe "Git webhook concurrency" do
  self.use_transactional_tests = false

  after do
    GitWebhookInbox.delete_all
    RepositoryConnection.delete_all
    GitInstallation.delete_all
    Service.delete_all
    Environment.delete_all
    Project.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  it "persists one message for concurrent delivery retries" do
    owner = User.create!(email: "webhook-concurrency@example.com", name: "Webhook")
    organization = Organizations::Create.call(principal: owner, name: "Webhook Concurrency").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    provider = build_fake_git_provider
    GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    )
    body = JSON.generate(
      installation: { id: "installation-1" },
      repository: { id: "repository-1" },
      ref: "refs/heads/main",
      before: "aaaaaaaa",
      after: "bbbbbbbb",
      pusher: { id: "provider-user-1" }
    )
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}"
    ready = Queue.new
    release = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          GitWebhooks::Ingest.call(
            provider:,
            provider_name: :github,
            delivery_id: "delivery-concurrent",
            event_type: "push",
            signature:,
            body:
          )
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results).to all(be_success)
    expect(results.count { |result| result.value.replayed }).to eq(1)
    expect(GitWebhookInbox.where(delivery_id: "delivery-concurrent").count).to eq(1)
  end
end
