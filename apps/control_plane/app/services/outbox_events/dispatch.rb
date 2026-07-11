module OutboxEvents
  class Dispatch
    MAX_ATTEMPTS = 5
    LEASE_DURATION = 30.seconds
    MAX_RETRY_DELAY = 5.minutes

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

      @limit.times do
        event = claim_next
        break unless event

        claim_token = event.claim_token
        outcome = publish(event)
        final_status = finalize(event, claim_token, outcome)
        counts[final_status] += 1 if final_status
      end

      Result.new(**counts)
    end

    private

    def claim_next
      ApplicationRecord.transaction(requires_new: true) do
        event = OutboxEvent
          .where(
            "(status = 'pending' AND available_at <= :now) OR " \
              "(status = 'delivering' AND locked_until <= :now)",
            now: @now
          )
          .order(:created_at, :id)
          .lock("FOR UPDATE SKIP LOCKED")
          .first
        return unless event

        event.update!(
          status: :delivering,
          attempt_count: event.attempt_count + 1,
          claim_token: SecureRandom.uuid_v7,
          locked_until: @now + LEASE_DURATION,
          last_error: nil
        )
        event
      end
    end

    def publish(event)
      result = @publisher.publish(envelope: event.envelope)
      return result if result.is_a?(DeliveryResult)

      DeliveryResult.rejected("Publisher returned an invalid result")
    rescue StandardError
      DeliveryResult.retry
    end

    def finalize(event, claim_token, outcome)
      final_status = nil
      event.with_lock do
        return unless event.status == "delivering" && event.claim_token == claim_token

        if outcome.published?
          event.update!(
            status: :published,
            claim_token: nil,
            locked_until: nil,
            published_at: @now,
            last_error: nil
          )
          final_status = :published
        elsif outcome.retryable? && event.attempt_count < MAX_ATTEMPTS
          event.update!(
            status: :pending,
            claim_token: nil,
            locked_until: nil,
            available_at: @now + retry_delay(event.attempt_count),
            last_error: outcome.safe_error
          )
          final_status = :retried
        else
          event.update!(
            status: :dead,
            claim_token: nil,
            locked_until: nil,
            last_error: outcome.safe_error
          )
          final_status = :dead
        end
      end
      final_status
    end

    def retry_delay(attempt_count)
      [ 5.seconds * (2**(attempt_count - 1)), MAX_RETRY_DELAY ].min
    end
  end
end
