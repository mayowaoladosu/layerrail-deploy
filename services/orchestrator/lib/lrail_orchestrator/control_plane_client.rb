# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module LrailOrchestrator
  class ControlPlaneClient
    class Unavailable < StandardError; end
    class Rejected < StandardError; end

    Command = Data.define(:event, :claim_token, :lease_expires_at)
    EVENT_TYPES = %w[
      deployment.requested.v1
      deployment.cancellation.requested.v1
      deployment.build.completed.v1
      deployment.runtime.ready.v1
      deployment.runtime.failed.v1
      deployment.runtime.canceled.v1
    ].freeze

    def initialize(base_url:, signer:, host_header: nil)
      @base_uri = URI(base_url)
      @signer = signer
      @host_header = host_header
    end

    def claim
      response = post(
        "/internal/v1/orchestrator/commands/claim",
        "event_types" => EVENT_TYPES
      )
      return if response.code.to_i == 204

      value = success_json(response)
      Command.new(
        event: value.fetch("event"),
        claim_token: value.fetch("claim_token").to_s,
        lease_expires_at: value.fetch("lease_expires_at").to_s
      )
    rescue KeyError, JSON::ParserError
      raise Rejected, "control plane returned an invalid command"
    end

    def finalize(event_id:, claim_token:, outcome:, safe_error: nil)
      payload = {
        "claim_token" => claim_token,
        "outcome" => outcome
      }
      payload["safe_error"] = safe_error.to_s.byteslice(0, 500) if safe_error
      success_json(
        post("/internal/v1/orchestrator/commands/#{event_id}/finalize", payload)
      )
    end

    def observe(operation)
      success_json(post("/internal/v1/orchestrator/operations", operation))
    end

    def prepare_build(input)
      success_json(post("/internal/v1/orchestrator/builds/prepare", input))
    end

    def cancel_build(signal)
      success_json(post("/internal/v1/orchestrator/builds/cancel", signal))
    end

    private

    def post(path, payload)
      body = JSON.generate(payload)
      raise Rejected, "request is too large" if body.bytesize > Contracts::MAX_BYTES

      uri = @base_uri + path
      request = Net::HTTP::Post.new(uri)
      @signer.headers(method: "POST", path:, body:).each do |name, value|
        request[name] = value
      end
      request["Host"] = @host_header if @host_header
      request.body = body
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 10
      ) { |http| http.request(request) }
    rescue IOError, SocketError, SystemCallError, Timeout::Error => error
      raise Unavailable, "control plane request failed", cause: error
    end

    def success_json(response)
      code = response.code.to_i
      raise Unavailable, "control plane unavailable" if code >= 500
      raise Rejected, "control plane rejected request" if code >= 400
      raise Rejected, "control plane response is too large" if response.body.bytesize > Contracts::MAX_BYTES

      JSON.parse(response.body)
    end
  end
end
