require "net/http"
require "time"

module LocalProvider
  class LogClient
    Entry = Data.define(:timestamp, :stream, :message)
    Result = Data.define(:status, :entries, :truncated, :retained)

    MAX_BODY_BYTES = 1.megabyte
    MAX_ENTRIES = 200
    MAX_MESSAGE_BYTES = 4096

    def self.fetch(organization_id:, deployment_id:, transport: nil)
      new(organization_id:, deployment_id:, transport:).call
    end

    def initialize(organization_id:, deployment_id:, transport:)
      @organization_id = organization_id.to_s
      @deployment_id = deployment_id.to_s
      @transport = transport || method(:perform_request)
    end

    def call
      path = "/v1/organizations/#{@organization_id}/deployments/#{@deployment_id}/logs"
      uri = URI.join(provider_url, path)
      request = signed_request(uri:, path:)
      response = @transport.call(uri, request)

      case response.code.to_i
      when 200
        parse(response.body.to_s)
      when 404
        Result.new(status: :not_found, entries: [], truncated: false, retained: false)
      else
        unavailable
      end
    rescue ArgumentError, Errno::ENOENT, JSON::ParserError, KeyError, Net::HTTPError, SocketError,
      SystemCallError, Timeout::Error, URI::InvalidURIError
      unavailable
    end

    private

    def signed_request(uri:, path:)
      request = Net::HTTP::Get.new(uri)
      timestamp = Time.current.to_i
      request_id = SecureRandom.uuid_v7
      input = [ timestamp, request_id, "GET", path, "" ].join("\n")
      signature = OpenSSL::HMAC.hexdigest("SHA256", SharedSecret.read, input)
      request["Accept"] = "application/json"
      request["X-Lrail-Timestamp"] = timestamp.to_s
      request["X-Lrail-Request-Id"] = request_id
      request["X-Lrail-Signature"] = "sha256=#{signature}"
      request
    end

    def perform_request(uri, request)
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 2,
        read_timeout: 2
      ) { |http| http.request(request) }
    end

    def parse(body)
      raise JSON::ParserError if body.bytesize > MAX_BODY_BYTES

      value = JSON.parse(body)
      raise JSON::ParserError unless value.is_a?(Hash) && value.keys.sort == %w[entries retained truncated]
      entries = value.fetch("entries")
      truncated = value.fetch("truncated")
      retained = value.fetch("retained")
      raise JSON::ParserError unless entries.is_a?(Array) && entries.length <= MAX_ENTRIES
      raise JSON::ParserError unless truncated.in?([ true, false ])
      raise JSON::ParserError unless retained.in?([ true, false ])

      parsed_entries = entries.map do |entry|
        raise JSON::ParserError unless entry.is_a?(Hash) && entry.keys.sort == %w[message stream timestamp]
        raise JSON::ParserError unless entry.fetch("stream") == "runtime"
        message = entry.fetch("message")
        raise JSON::ParserError unless message.is_a?(String) && message.present? && message.bytesize <= MAX_MESSAGE_BYTES

        Entry.new(
          timestamp: Time.iso8601(entry.fetch("timestamp")),
          stream: "runtime",
          message:
        )
      end
      Result.new(status: :ok, entries: parsed_entries, truncated:, retained:)
    end

    def provider_url
      value = ENV.fetch("LOCAL_PROVIDER_URL", "http://local-provider:9000")
      uri = URI.parse(value)
      raise ArgumentError unless uri.is_a?(URI::HTTP) && uri.host && uri.path.in?([ "", "/" ])

      value.end_with?("/") ? value : "#{value}/"
    end

    def unavailable
      Result.new(status: :unavailable, entries: [], truncated: false, retained: false)
    end
  end
end
