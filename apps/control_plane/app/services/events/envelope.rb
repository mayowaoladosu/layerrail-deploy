module Events
  class Envelope
    class Invalid < StandardError; end

    KEYS = %w[
      event_id event_type occurred_at organization_id resource_id correlation_id
      idempotency_key producer schema_version data
    ].freeze
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    EVENT_TYPE_PATTERN = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\.v[1-9][0-9]*\z/
    PRODUCER_PATTERN = /\A[a-z][a-z0-9-]*\z/
    MAX_DATA_BYTES = 64.kilobytes

    attr_reader :event_id,
      :event_type,
      :occurred_at,
      :organization_id,
      :resource_id,
      :correlation_id,
      :idempotency_key,
      :producer,
      :schema_version,
      :data

    def self.build(**attributes)
      new(attributes)
    end

    def self.parse(value)
      raise Invalid unless value.is_a?(Hash)

      new(value)
    end

    def self.canonicalize(value)
      case value
      when Hash
        value.to_h { |key, child| [ key.to_s, canonicalize(child) ] }.sort.to_h.freeze
      when Array
        value.map { |child| canonicalize(child) }.freeze
      when String
        value.dup.freeze
      when Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        raise Invalid
      end
    end

    def initialize(attributes)
      normalized = attributes.to_h { |key, value| [ key.to_s, value ] }
      raise Invalid unless normalized.keys.sort == KEYS.sort

      @event_id = normalized.fetch("event_id").to_s
      @event_type = normalized.fetch("event_type").to_s
      @occurred_at = parse_time(normalized.fetch("occurred_at"))
      @organization_id = normalized.fetch("organization_id").to_s
      @resource_id = normalized.fetch("resource_id").to_s
      @correlation_id = normalized.fetch("correlation_id").to_s
      @idempotency_key = normalized.fetch("idempotency_key").to_s
      @producer = normalized.fetch("producer").to_s
      @schema_version = normalized.fetch("schema_version")
      @data = self.class.canonicalize(normalized.fetch("data"))
      validate!
      freeze
    end

    def to_h
      {
        "event_id" => event_id,
        "event_type" => event_type,
        "occurred_at" => occurred_at.iso8601(6),
        "organization_id" => organization_id,
        "resource_id" => resource_id,
        "correlation_id" => correlation_id,
        "idempotency_key" => idempotency_key,
        "producer" => producer,
        "schema_version" => schema_version,
        "data" => data
      }
    end

    def digest
      Digest::SHA256.hexdigest(JSON.generate(to_h))
    end

    private

    def parse_time(value)
      value.respond_to?(:iso8601) && !value.is_a?(String) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      raise Invalid
    end

    def validate!
      ids = [ event_id, organization_id, resource_id, correlation_id ]
      raise Invalid unless ids.all? { |id| UUID_PATTERN.match?(id) }
      raise Invalid unless EVENT_TYPE_PATTERN.match?(event_type)
      raise Invalid unless idempotency_key.present? && idempotency_key.length <= 255 && idempotency_key == idempotency_key.strip
      raise Invalid unless producer.length <= 63 && PRODUCER_PATTERN.match?(producer)
      raise Invalid unless schema_version == 1
      raise Invalid unless data.is_a?(Hash) && JSON.generate(data).bytesize <= MAX_DATA_BYTES
    end
  end
end
