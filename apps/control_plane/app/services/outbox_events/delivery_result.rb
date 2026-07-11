module OutboxEvents
  DeliveryResult = Data.define(:outcome, :safe_error) do
    OUTCOMES = %i[published retry rejected].freeze

    def self.published
      new(outcome: :published, safe_error: nil)
    end

    def self.retry(safe_error = "Publisher unavailable")
      new(outcome: :retry, safe_error:)
    end

    def self.rejected(safe_error)
      new(outcome: :rejected, safe_error:)
    end

    def initialize(outcome:, safe_error:)
      normalized_outcome = outcome.to_sym
      raise ArgumentError unless normalized_outcome.in?(OUTCOMES)

      normalized_error = safe_error&.to_s&.slice(0, 1000)
      raise ArgumentError if normalized_outcome != :published && normalized_error.blank?

      super(outcome: normalized_outcome, safe_error: normalized_error)
    end

    def published?
      outcome == :published
    end

    def retryable?
      outcome == :retry
    end
  end
end
