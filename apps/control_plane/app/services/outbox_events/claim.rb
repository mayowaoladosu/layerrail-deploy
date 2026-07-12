module OutboxEvents
  class Claim
    class InvalidRequest < StandardError; end

    Result = Data.define(:event, :claim_token, :replayed)
    MAX_EVENT_TYPES = 16
    MAX_LEASE = 5.minutes

    def self.call(request_id:, event_types:, now:, lease_duration:)
      new(request_id:, event_types:, now:, lease_duration:).call
    end

    def initialize(request_id:, event_types:, now:, lease_duration:)
      @request_id = request_id.to_s
      @event_types = Array(event_types).map(&:to_s).uniq.sort
      @now = now
      @lease_duration = lease_duration
      validate!
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        existing = OutboxEvent.lock.find_by(claim_request_id: @request_id)
        if existing&.status == "delivering" && existing.locked_until > @now
          return Result.new(event: existing, claim_token: existing.claim_token, replayed: true)
        end
        return if existing && existing.status != "delivering"

        event = OutboxEvent
          .where(event_type: @event_types)
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
          claim_request_id: @request_id,
          locked_until: @now + @lease_duration,
          last_error: nil
        )

        Result.new(event:, claim_token: event.claim_token, replayed: false)
      end
    end

    private

    def validate!
      raise InvalidRequest unless Events::Envelope::UUID_PATTERN.match?(@request_id)
      raise InvalidRequest unless @event_types.length.between?(1, MAX_EVENT_TYPES)
      raise InvalidRequest unless @event_types.all? { |event_type| Events::Envelope::EVENT_TYPE_PATTERN.match?(event_type) }
      raise InvalidRequest unless @lease_duration.positive? && @lease_duration <= MAX_LEASE
    end
  end
end
