module OutboxEvents
  class Finalize
    class OutcomeConflict < StandardError; end
    class StaleClaim < StandardError; end

    MAX_ATTEMPTS = 5
    MAX_RETRY_DELAY = 5.minutes

    Result = Data.define(:status, :replayed)

    def self.call(event:, claim_token:, outcome:, now:)
      new(event:, claim_token:, outcome:, now:).call
    end

    def initialize(event:, claim_token:, outcome:, now:)
      @event = event
      @claim_token = claim_token.to_s
      @outcome = outcome
      @now = now
      raise ArgumentError unless @outcome.is_a?(DeliveryResult)
    end

    def call
      @event.with_lock do
        return replay_terminal if @event.status.in?(%w[published dead])
        unless @event.status == "delivering" && @event.claim_token == @claim_token
          raise StaleClaim
        end

        if @outcome.published?
          @event.update!(
            status: :published,
            claim_token: nil,
            locked_until: nil,
            published_at: @now,
            last_error: nil
          )
        elsif @outcome.retryable? && @event.attempt_count < MAX_ATTEMPTS
          @event.update!(
            status: :pending,
            claim_token: nil,
            locked_until: nil,
            available_at: @now + retry_delay(@event.attempt_count),
            last_error: @outcome.safe_error
          )
        else
          @event.update!(
            status: :dead,
            claim_token: nil,
            locked_until: nil,
            last_error: @outcome.safe_error
          )
        end

        Result.new(status: @event.status, replayed: false)
      end
    end

    private

    def replay_terminal
      compatible = if @event.status == "published"
        @outcome.published?
      else
        !@outcome.published?
      end
      raise OutcomeConflict unless compatible

      Result.new(status: @event.status, replayed: true)
    end

    def retry_delay(attempt_count)
      [ 5.seconds * (2**(attempt_count - 1)), MAX_RETRY_DELAY ].min
    end
  end
end
