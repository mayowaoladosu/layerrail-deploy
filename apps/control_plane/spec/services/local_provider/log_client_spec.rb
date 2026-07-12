require "rails_helper"

RSpec.describe LocalProvider::LogClient do
  Response = Data.define(:code, :body)
  SECRET = "local-provider-log-client-secret-at-least-32-bytes".freeze

  around do |example|
    Dir.mktmpdir("provider-log-client") do |directory|
      path = Pathname(directory).join("secret")
      path.write(SECRET)
      previous_secret = ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"]
      previous_url = ENV["LOCAL_PROVIDER_URL"]
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = path.to_s
      ENV["LOCAL_PROVIDER_URL"] = "http://provider.internal:9000"
      example.run
    ensure
      ENV["LOCAL_PROVIDER_SHARED_SECRET_FILE"] = previous_secret
      ENV["LOCAL_PROVIDER_URL"] = previous_url
    end
  end

  it "signs a tenant-bound request and parses bounded runtime entries" do
    organization_id = SecureRandom.uuid_v7
    deployment_id = SecureRandom.uuid_v7
    captured = nil
    transport = lambda do |uri, request|
      captured = [ uri, request ]
      Response.new(
        code: "200",
        body: JSON.generate(
          entries: [
            {
              timestamp: "2026-07-12T00:00:00.123456Z",
              stream: "runtime",
              message: "sample ready"
            }
          ],
          truncated: false,
          retained: false
        )
      )
    end

    result = described_class.fetch(organization_id:, deployment_id:, transport:)
    uri, request = captured
    path = "/v1/organizations/#{organization_id}/deployments/#{deployment_id}/logs"
    input = [ request["X-Lrail-Timestamp"], request["X-Lrail-Request-Id"], "GET", path, "" ].join("\n")
    expected = OpenSSL::HMAC.hexdigest("SHA256", SECRET, input)

    expect(uri.to_s).to eq("http://provider.internal:9000#{path}")
    expect(request["X-Lrail-Signature"]).to eq("sha256=#{expected}")
    expect(result).to have_attributes(status: :ok, truncated: false, retained: false)
    expect(result.entries.sole).to have_attributes(
      timestamp: Time.iso8601("2026-07-12T00:00:00.123456Z"),
      stream: "runtime",
      message: "sample ready"
    )
  end

  it "fails closed for unavailable, missing and malformed provider responses" do
    arguments = {
      organization_id: SecureRandom.uuid_v7,
      deployment_id: SecureRandom.uuid_v7
    }

    missing = described_class.fetch(
      **arguments,
      transport: ->(*) { Response.new(code: "404", body: "") }
    )
    malformed = described_class.fetch(
      **arguments,
      transport: ->(*) { Response.new(code: "200", body: '{"entries":[{"message":"secret"}]}') }
    )
    unavailable = described_class.fetch(
      **arguments,
      transport: ->(*) { raise Errno::ECONNREFUSED }
    )

    expect(missing).to have_attributes(status: :not_found, entries: [], truncated: false, retained: false)
    expect(malformed).to have_attributes(status: :unavailable, entries: [], truncated: false, retained: false)
    expect(unavailable).to have_attributes(status: :unavailable, entries: [], truncated: false, retained: false)
  end
end
