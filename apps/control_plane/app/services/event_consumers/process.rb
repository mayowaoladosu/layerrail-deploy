module EventConsumers
  class Process
    class Conflict < StandardError; end
    class InvalidResult < StandardError; end

    Result = Data.define(:receipt, :result, :replayed)

    def self.call(consumer:, envelope:, &)
      new(consumer:, envelope:).call(&)
    end

    def initialize(consumer:, envelope:)
      @consumer = consumer.to_s
      @envelope = Events::Envelope.parse(envelope)
      @payload_digest = @envelope.digest
    end

    def call
      receipt = receive

      ApplicationRecord.transaction(requires_new: true) do
        receipt.lock!
        validate_receipt!(receipt)
        return replay(receipt) if receipt.status == "completed"

        result = canonical_result(yield)
        receipt.update!(status: :completed, result:, consumed_at: Time.current)

        Result.new(receipt:, result:, replayed: false)
      end
    end

    private

    def receive
      ApplicationRecord.transaction(requires_new: true) do
        lock_event!
        existing = EventReceipt.find_by(consumer: @consumer, event_id: @envelope.event_id)
        if existing
          validate_receipt!(existing)
          return existing
        end

        EventReceipt.create!(
          organization: Organization.find(@envelope.organization_id),
          consumer: @consumer,
          event_id: @envelope.event_id,
          event_type: @envelope.event_type,
          payload_digest: @payload_digest,
          status: :processing,
          result: {}
        )
      end
    end

    def lock_event!
      key = "#{@consumer}:#{@envelope.event_id}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end

    def canonical_result(value)
      raise InvalidResult unless value.is_a?(Hash)

      result = Events::Envelope.canonicalize(value)
      raise InvalidResult if JSON.generate(result).bytesize > 64.kilobytes

      result
    end

    def replay(existing)
      validate_receipt!(existing)
      raise Conflict unless existing.status == "completed"

      Result.new(receipt: existing, result: existing.result, replayed: true)
    end

    def validate_receipt!(existing)
      unless existing.organization_id == @envelope.organization_id &&
          existing.event_type == @envelope.event_type &&
          existing.payload_digest == @payload_digest
        raise Conflict
      end
    end
  end
end
