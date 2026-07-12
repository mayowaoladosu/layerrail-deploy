require "rails_helper"

RSpec.describe Authentication::RequestLimiter do
  it "enforces the email budget while storing no email or IP address" do
    results = 6.times.map do
      described_class.allow?(email: "limited@example.com", ip: "192.0.2.23")
    end

    expect(results).to eq([ true, true, true, true, true, false ])
    expect(AuthenticationRequestAttempt.count).to eq(5)
    expect(AuthenticationRequestAttempt.pluck(:email_digest, :ip_digest).flatten.compact)
      .to all(match(/\A[0-9a-f]{64}\z/))
    expect(AuthenticationRequestAttempt.all.map(&:attributes).to_s)
      .not_to include("limited@example.com", "192.0.2.23")
  end

  it "enforces the shared IP budget across distinct addresses" do
    results = 21.times.map do |index|
      described_class.allow?(
        email: "ip-budget-#{index}@example.com",
        ip: "192.0.2.24"
      )
    end

    expect(results.first(20)).to all(be(true))
    expect(results.last).to be(false)
    expect(AuthenticationRequestAttempt.count).to eq(20)
  end
end
