require "rails_helper"

RSpec.describe "Authentication concurrency" do
  self.use_transactional_tests = false

  after do
    AuthenticationSession.delete_all
    LoginChallenge.delete_all
    EventReceipt.delete_all
    OutboxEvent.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  def run_concurrently(values, &block)
    ready = Queue.new
    release = Queue.new
    threads = values.map do |value|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          block.call(value)
        rescue StandardError => error
          error
        end
      end
    end
    values.length.times { ready.pop }
    values.length.times { release << true }
    threads.map(&:value)
  end

  it "consumes one challenge once under concurrent exchange" do
    issued = Authentication::Challenges.issue(email: "auth-race@example.com", ip: "192.0.2.40")

    results = run_concurrently([ issued.token, issued.token ]) do |token|
      Authentication::Challenges.complete(
        token:,
        session_kind: :api,
        ip: "192.0.2.40",
        user_agent: "Concurrent Client"
      )
    end

    expect(results.count { |result| result.is_a?(Authentication::Challenges::Completed) }).to eq(1)
    expect(results.count { |result| result.is_a?(Authentication::Challenges::InvalidChallenge) }).to eq(1)
    expect(User.count).to eq(1)
    expect(Organization.count).to eq(1)
    expect(AuthenticationSession.count).to eq(1)
    expect(issued.challenge.reload.consumed_at).to be_present
  end

  it "bootstraps only one organization for concurrent first identities" do
    first = Authentication::Challenges.issue(email: "first-race@example.com", ip: "192.0.2.41")
    second = Authentication::Challenges.issue(email: "second-race@example.com", ip: "192.0.2.42")

    results = run_concurrently([ first.token, second.token ]) do |token|
      Authentication::Challenges.complete(
        token:,
        session_kind: :api,
        ip: nil,
        user_agent: "Concurrent Client"
      )
    end

    expect(results.count { |result| result.is_a?(Authentication::Challenges::Completed) }).to eq(1)
    expect(results.count { |result| result.is_a?(Authentication::Challenges::InvalidChallenge) }).to eq(1)
    expect(User.count).to eq(1)
    expect(Organization.count).to eq(1)
    expect(Membership.count).to eq(1)
    expect(AuthenticationSession.count).to eq(1)
    expect(results.count { |result| result.is_a?(Authentication::Challenges::Completed) && result.organization }).to eq(1)
  end

  it "enforces the per-email challenge budget under concurrency" do
    2.times do
      Authentication::Challenges.issue(
        email: "concurrent-limit@example.com",
        ip: "192.0.2.43"
      )
    end
    results = run_concurrently(4.times.to_a) do
      Authentication::Challenges.issue(
        email: "concurrent-limit@example.com",
        ip: "192.0.2.43"
      )
    end

    expect(results.count(&:rate_limited)).to eq(1)
    expect(LoginChallenge.where(email: "concurrent-limit@example.com").count).to eq(5)
  end
end
