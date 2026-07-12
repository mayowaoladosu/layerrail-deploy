module OutboxEvents
  class Dispatch
    LEASE_DURATION = 30.seconds

    Result = Data.define(:published, :retried, :dead)

    def self.call(publisher:, now: Time.current, limit: 100)
      new(publisher:, now:, limit:).call
    end

    def initialize(publisher:, now:, limit:)
      @publisher = publisher
      @now = now
      @limit = Integer(limit).clamp(0, 1000)
    end

    def call
      counts = { published: 0, retried: 0, dead: 0 }
      event_types = OutboxEvent.distinct.pluck(:event_type)
      return Result.new(**counts) if event_types.empty?

      @limit.times do
        claim = Claim.call(
          request_id: SecureRandom.uuid_v7,
          event_types:,
          now: @now,
          lease_duration: LEASE_DURATION
        )
        break unless claim

        outcome = publish(claim.event)
        finalization = Finalize.call(
          event: claim.event,
          claim_token: claim.claim_token,
          outcome:,
          now: @now
        )
        counts[count_for(finalization.status)] += 1
      end

      Result.new(**counts)
    end

    private

    def publish(event)
      result = @publisher.publish(envelope: event.envelope)
      return result if result.is_a?(DeliveryResult)

      DeliveryResult.rejected("Publisher returned an invalid result")
    rescue StandardError
      DeliveryResult.retry
    end

    def count_for(status)
      {
        "published" => :published,
        "pending" => :retried,
        "dead" => :dead
      }.fetch(status)
    end
  end
end
