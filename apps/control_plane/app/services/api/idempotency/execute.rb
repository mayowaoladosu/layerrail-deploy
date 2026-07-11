module Api
  module Idempotency
    class Execute
      class MissingKey < StandardError; end
      class InvalidKey < StandardError; end
      class Conflict < StandardError; end

      Result = Data.define(:status, :body, :replayed)

      def self.call(organization:, key:, operation:, payload:, &)
        new(organization:, key:, operation:, payload:).call(&)
      end

      def initialize(organization:, key:, operation:, payload:)
        @organization = organization
        @key = key.to_s
        @operation = operation
        @fingerprint = fingerprint(operation:, payload:)
        validate_key!
      end

      def call
        ApplicationRecord.transaction(requires_new: true) do
          acquire_lock!

          existing = IdempotencyRecord.find_by(organization: @organization, key: @key)
          return replay(existing) if existing

          outcome = yield
          status = Rack::Utils.status_code(outcome.fetch(:status))
          body = outcome.fetch(:body)
          resource = outcome[:resource]

          IdempotencyRecord.create!(
            organization: @organization,
            key: @key,
            operation: @operation,
            request_fingerprint: @fingerprint,
            response_status: status,
            response_body: body,
            resource_type: resource&.class&.name,
            resource_id: resource&.id
          )

          Result.new(status:, body:, replayed: false)
        end
      end

      private

      def validate_key!
        raise MissingKey if @key.blank?
        raise InvalidKey if @key.length > 255 || @key != @key.strip
      end

      def acquire_lock!
        lock_key = "#{@organization.id}:#{@key}"
        quoted_key = ApplicationRecord.connection.quote(lock_key)

        ApplicationRecord.connection.execute(
          "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
        )
      end

      def replay(record)
        raise Conflict unless record.request_fingerprint == @fingerprint

        Result.new(
          status: record.response_status,
          body: record.response_body,
          replayed: true
        )
      end

      def fingerprint(operation:, payload:)
        canonical = canonicalize(
          "operation" => operation,
          "payload" => payload
        )

        Digest::SHA256.hexdigest(JSON.generate(canonical))
      end

      def canonicalize(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s, canonicalize(child) ] }.sort.to_h
        when Array
          value.map { |child| canonicalize(child) }
        else
          value
        end
      end
    end
  end
end
