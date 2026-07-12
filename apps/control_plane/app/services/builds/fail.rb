module Builds
  class Fail
    class FailureConflict < StandardError; end
    class InvalidBuildState < StandardError; end

    Result = Data.define(:build, :deployment, :replayed)

    def self.call(build:, error:, retryable:, evidence: {})
      new(build:, error:, retryable:, evidence:).call
    end

    def initialize(build:, error:, retryable:, evidence:)
      @build = build
      @error = JSON.parse(JSON.generate(error))
      @retryable = retryable == true
      @evidence = JSON.parse(JSON.generate(evidence))
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @build.lock!
        if @build.status == "failed"
          expected_evidence = failure_evidence
          raise FailureConflict unless @build.evidence == expected_evidence

          return Result.new(build: @build, deployment: @build.deployment, replayed: true)
        end
        raise InvalidBuildState unless @build.status == "running"

        @build.update!(
          status: :failed,
          evidence: failure_evidence,
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

    private

    def failure_evidence
      @evidence.merge("error" => @error, "retryable" => @retryable)
    end
  end
end
