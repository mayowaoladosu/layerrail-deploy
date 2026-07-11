module OutboxEvents
  class Publish
    class Conflict < StandardError; end

    Result = Data.define(:event, :replayed)

    def self.call(organization:, resource_id:, event_type:, correlation_id:, idempotency_key:, producer:, data:)
      new(
        organization:,
        resource_id:,
        event_type:,
        correlation_id:,
        idempotency_key:,
        producer:,
        data:
      ).call
    end

    def initialize(organization:, resource_id:, event_type:, correlation_id:, idempotency_key:, producer:, data:)
      @organization = organization
      @resource_id = resource_id.to_s
      @event_type = event_type.to_s
      @correlation_id = correlation_id.to_s
      @idempotency_key = idempotency_key.to_s
      @producer = producer.to_s
      @data = canonicalize(data)
      @data_digest = Digest::SHA256.hexdigest(JSON.generate(@data))
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        lock_idempotency!
        existing = OutboxEvent.find_by(
          organization: @organization,
          producer: @producer,
          idempotency_key: @idempotency_key
        )
        return replay(existing) if existing

        occurred_at = Time.current
        event = OutboxEvent.create!(
          organization: @organization,
          resource_id: @resource_id,
          event_type: @event_type,
          correlation_id: @correlation_id,
          idempotency_key: @idempotency_key,
          producer: @producer,
          schema_version: 1,
          data: @data,
          data_digest: @data_digest,
          occurred_at:,
          status: :pending,
          attempt_count: 0,
          available_at: occurred_at
        )

        Result.new(event:, replayed: false)
      end
    end

    private

    def canonicalize(value)
      raise Events::Envelope::Invalid unless value.is_a?(Hash)

      Events::Envelope.canonicalize(value)
    end

    def lock_idempotency!
      key = "#{@organization.id}:#{@producer}:#{@idempotency_key}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end

    def replay(existing)
      unless existing.resource_id == @resource_id &&
          existing.event_type == @event_type &&
          existing.correlation_id == @correlation_id &&
          existing.data_digest == @data_digest
        raise Conflict
      end

      Result.new(event: existing, replayed: true)
    end
  end
end
