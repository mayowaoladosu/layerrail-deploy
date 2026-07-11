module Builds
  class Fail
    class FailureConflict < StandardError; end
    class InvalidBuildState < StandardError; end

    Result = Data.define(:build, :deployment, :replayed)

    def self.call(build:, error:, retryable:)
      new(build:, error:, retryable:).call
    end

    def initialize(build:, error:, retryable:)
      @build = build
      @error = JSON.parse(JSON.generate(error))
      @retryable = retryable == true
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @build.lock!
        if @build.status == "failed"
          expected_evidence = { "error" => @error, "retryable" => @retryable }
          raise FailureConflict unless @build.evidence == expected_evidence

          return Result.new(build: @build, deployment: @build.deployment, replayed: true)
        end
        raise InvalidBuildState unless @build.status == "running"

        @build.update!(
          status: :failed,
          evidence: { "error" => @error, "retryable" => @retryable },
          finished_at: Time.current
        )
        deployment = @build.deployment
        deployment = Deployments::Transition.call(
          deployment:,
          to: @retryable ? :preparing : :failed,
          actor: nil,
          cause: @retryable ? "build_retryable" : "build_failed",
          expected_lock_version: deployment.lock_version,
          error: @error
        ).deployment

        Result.new(build: @build, deployment:, replayed: false)
      end
    end
  end
end
