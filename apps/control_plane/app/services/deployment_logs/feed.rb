require "base64"
require "time"

module DeploymentLogs
  class Feed
    class InvalidCursor < StandardError; end

    Entry = Data.define(:timestamp, :stream, :level, :message, :identity)
    Result = Data.define(:entries, :next_cursor, :provider_status, :truncated)

    MAX_LIMIT = 100
    MAX_CURSOR_BYTES = 512

    STATUS_MESSAGES = {
      "created" => "Deployment request accepted.",
      "queued" => "Deployment queued for execution.",
      "preparing" => "Preparing the deployment artifact.",
      "building" => "Build attempt started.",
      "scanning" => "Artifact verification started.",
      "deploying" => "Starting the candidate revision.",
      "verifying" => "Waiting for the readiness check.",
      "ready" => "Revision passed readiness checks.",
      "promoted" => "Revision promoted to the environment URL.",
      "superseded" => "Revision moved out of the environment URL.",
      "canceling" => "Cancellation requested.",
      "canceled" => "Deployment canceled.",
      "failed" => "Deployment failed."
    }.freeze

    def self.call(deployment:, provider_result:, cursor: nil, limit: 25, include_history: false)
      new(deployment:, provider_result:, cursor:, limit:, include_history:).call
    end

    def initialize(deployment:, provider_result:, cursor:, limit:, include_history:)
      @deployment = deployment
      @provider_result = provider_result
      @cursor = cursor.to_s.presence
      @limit = Integer(limit)
      @include_history = include_history == true
      raise ArgumentError unless @limit.between?(1, MAX_LIMIT)
    end

    def call
      persisted_entries = transition_entries + build_entries
      runtime_log_entries = runtime_entries
      entries = (persisted_entries + runtime_log_entries)
        .uniq(&:identity)
        .sort_by { |entry| sort_key(entry) }
      entries = if @cursor
        cursor_key = decode_cursor(@cursor)
        entries.select { |entry| (sort_key(entry) <=> cursor_key).positive? }.first(@limit)
      elsif @include_history
        persisted_entries = persisted_entries.uniq(&:identity).last(@limit)
        runtime_budget = [ @limit - persisted_entries.length, 0 ].max
        (persisted_entries + runtime_log_entries.uniq(&:identity).last(runtime_budget))
          .sort_by { |entry| sort_key(entry) }
      else
        entries.last(@limit)
      end

      Result.new(
        entries:,
        next_cursor: entries.any? ? encode_cursor(entries.last) : @cursor,
        provider_status: @provider_result.status,
        truncated: @provider_result.truncated
      )
    rescue ArgumentError, JSON::ParserError
      raise InvalidCursor
    end

    private

    def transition_entries
      @deployment.deployment_transitions.order(:sequence).map do |transition|
        error_message = transition.error.is_a?(Hash) ? transition.error["message"] : nil
        error_message = nil unless error_message.is_a?(String)
        Entry.new(
          timestamp: transition.occurred_at,
          stream: "system",
          level: transition.to_status == "failed" ? "error" : level_for(transition.to_status),
          message: error_message.presence || STATUS_MESSAGES.fetch(transition.to_status),
          identity: "transition:#{transition.id}"
        )
      end
    end

    def build_entries
      @deployment.builds.order(:attempt).flat_map do |build|
        entries = [
          Entry.new(
            timestamp: build.started_at,
            stream: "build",
            level: "info",
            message: "Build attempt #{build.attempt} started.",
            identity: "build:#{build.id}:started"
          )
        ]
        if build.finished_at
          entries << Entry.new(
            timestamp: build.finished_at,
            stream: "build",
            level: build.status == "failed" ? "error" : "info",
            message: "Build attempt #{build.attempt} #{build.status}.",
            identity: "build:#{build.id}:finished"
          )
        end
        entries
      end
    end

    def runtime_entries
      @provider_result.entries.each_with_index.map do |entry, index|
        digest = Digest::SHA256.hexdigest(entry.message)
        Entry.new(
          timestamp: entry.timestamp,
          stream: "runtime",
          level: runtime_level(entry.message),
          message: entry.message,
          identity: "runtime:#{entry.timestamp.utc.iso8601(9)}:#{digest}:#{index}"
        )
      end
    end

    def runtime_level(message)
      return "error" if message.match?(/\b(error|exception|fatal)\b/i)
      return "warning" if message.match?(/\bwarn(?:ing)?\b/i)

      "info"
    end

    def level_for(status)
      status.in?(%w[canceling superseded]) ? "warning" : "info"
    end

    def sort_key(entry)
      [ entry.timestamp.to_r, entry.identity ]
    end

    def encode_cursor(entry)
      Base64.urlsafe_encode64(
        JSON.generate(
          "version" => 1,
          "timestamp" => entry.timestamp.utc.iso8601(9),
          "identity" => entry.identity
        ),
        padding: false
      )
    end

    def decode_cursor(cursor)
      raise InvalidCursor if cursor.bytesize > MAX_CURSOR_BYTES

      value = JSON.parse(Base64.urlsafe_decode64(cursor))
      raise InvalidCursor unless value.is_a?(Hash) && value.keys.sort == %w[identity timestamp version]
      raise InvalidCursor unless value.fetch("version") == 1
      identity = value.fetch("identity")
      raise InvalidCursor unless identity.is_a?(String) && identity.bytesize.between?(1, 255)

      [ Time.iso8601(value.fetch("timestamp")).to_r, identity ]
    rescue ArgumentError, KeyError
      raise InvalidCursor
    end
  end
end
