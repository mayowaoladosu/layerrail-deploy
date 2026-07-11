module GitProviders
  Error = Data.define(:code, :message, :retryable, :retry_after)

  class Result
    attr_reader :value, :error

    def self.success(value)
      new(value:, error: nil)
    end

    def self.failure(code, message:, retryable: false, retry_after: nil)
      new(
        value: nil,
        error: Error.new(code:, message:, retryable:, retry_after:)
      )
    end

    def initialize(value:, error:)
      @value = value
      @error = error
      freeze
    end

    def success?
      error.nil?
    end

    def failure?
      !success?
    end
  end
end
