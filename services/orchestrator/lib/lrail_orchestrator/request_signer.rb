# frozen_string_literal: true

require "openssl"
require "securerandom"

module LrailOrchestrator
  class RequestSigner
    def initialize(secret_path)
      @secret = File.binread(secret_path).strip
      raise ArgumentError, "orchestrator secret is invalid" unless @secret.bytesize.between?(32, 4096)
    end

    def headers(method:, path:, body:, request_id: SecureRandom.uuid, timestamp: Time.now.to_i)
      input = [timestamp, request_id, method.to_s.upcase, path, body].join("\n")
      signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, input)
      {
        "Content-Type" => "application/json",
        "X-Lrail-Timestamp" => timestamp.to_s,
        "X-Lrail-Request-Id" => request_id,
        "X-Lrail-Signature" => "sha256=#{signature}"
      }
    end
  end
end
