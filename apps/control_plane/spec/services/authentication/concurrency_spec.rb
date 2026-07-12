require "rails_helper"

RSpec.describe "Rodauth authentication concurrency" do
  include RodauthHelpers

  self.use_transactional_tests = false

  after do
    ApplicationRecord.connection.execute("DELETE FROM user_identities")
    ApplicationRecord.connection.execute("DELETE FROM user_active_session_keys")
    ApplicationRecord.connection.execute("DELETE FROM user_email_auth_keys")
    RodauthLoginClaim.delete_all
    AuthenticationRequestAttempt.delete_all
    EventReceipt.delete_all
    OutboxEvent.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  def request_link(email, ip)
    RodauthApp.rodauth.email_auth_request(
      login: email,
      session: {},
      env: { "REMOTE_ADDR" => ip }
    )
    last_email_auth_key
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

  it "claims one Rodauth email token once under concurrent exchange" do
    key = request_link("auth-race@example.com", "192.0.2.40")

    results = run_concurrently([ key, key ]) do |token|
      Authentication::RodauthSessions.exchange(token)
    end

    expect(results.count { |result| result.is_a?(Authentication::RodauthSessions::Result) }).to eq(1)
    expect(results.count { |result| result.is_a?(Authentication::RodauthSessions::InvalidToken) }).to eq(1)
    expect(Organization.count).to eq(1)
    expect(Membership.where(role: :owner).count).to eq(1)
    expect(RodauthLoginClaim.count).to eq(1)
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys"
    ).to_i).to eq(1)
  end

  it "bootstraps only one organization owner for concurrent first identities" do
    first = request_link("first-race@example.com", "192.0.2.41")
    second = request_link("second-race@example.com", "192.0.2.42")

    results = run_concurrently([ first, second ]) do |token|
      Authentication::RodauthSessions.exchange(token)
    end

    expect(results.count { |result| result.is_a?(Authentication::RodauthSessions::Result) }).to eq(1)
    expect(results.count { |result| result.is_a?(Authentication::RodauthSessions::InvalidToken) }).to eq(1)
    expect(Organization.count).to eq(1)
    expect(Membership.where(role: :owner).count).to eq(1)
    expect(User.where(authentication_state: :active).count).to eq(1)
    expect(User.where(authentication_state: :blocked).count).to eq(1)
  end

  it "keeps the per-email request budget correct under concurrency" do
    2.times do
      Authentication::RequestLimiter.allow?(
        email: "concurrent-limit@example.com",
        ip: "192.0.2.43"
      )
    end
    results = run_concurrently(4.times.to_a) do
      Authentication::RequestLimiter.allow?(
        email: "concurrent-limit@example.com",
        ip: "192.0.2.43"
      )
    end

    expect(results.count(true)).to eq(3)
    expect(results.count(false)).to eq(1)
    expect(AuthenticationRequestAttempt.count).to eq(5)
  end
end
