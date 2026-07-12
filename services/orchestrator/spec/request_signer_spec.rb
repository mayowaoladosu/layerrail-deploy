# frozen_string_literal: true

require "tmpdir"

RSpec.describe LrailOrchestrator::RequestSigner do
  it "signs the bounded method, path and exact body without exposing the secret" do
    Dir.mktmpdir("orchestrator-signer") do |directory|
      secret = "orchestrator-signing-secret-at-least-32-bytes"
      path = File.join(directory, "secret")
      File.binwrite(path, secret)
      signer = described_class.new(path)
      headers = signer.headers(
        method: "post",
        path: "/internal/v1/orchestrator/operations",
        body: '{"contract_version":1}',
        request_id: "019b9a80-0000-7000-8000-000000000010",
        timestamp: 1_784_000_000
      )

      expect(headers.fetch("X-Lrail-Signature")).to match(/\Asha256=[0-9a-f]{64}\z/)
      expect(headers.to_json).not_to include(secret)
    end
  end
end
