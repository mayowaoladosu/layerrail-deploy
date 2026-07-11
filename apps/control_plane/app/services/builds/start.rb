module Builds
  class Start
    class InvalidDeploymentState < StandardError; end
    class StaleDeployment < StandardError; end

    Result = Data.define(:build, :deployment, :replayed)

    def self.call(deployment:, idempotency_key:, expected_lock_version:)
      new(deployment:, idempotency_key:, expected_lock_version:).call
    end

    def initialize(deployment:, idempotency_key:, expected_lock_version:)
      @deployment = deployment
      @idempotency_key = idempotency_key.to_s
      @expected_lock_version = expected_lock_version
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @deployment.lock!
        existing = @deployment.builds.find_by(idempotency_key: @idempotency_key)
        return Result.new(build: existing, deployment: @deployment, replayed: true) if existing
        raise StaleDeployment unless @deployment.lock_version == @expected_lock_version
        raise InvalidDeploymentState unless @deployment.status == "preparing"

        attempt = @deployment.builds.maximum(:attempt).to_i + 1
        build = @deployment.builds.create!(
          organization: @deployment.organization,
          attempt:,
          idempotency_key: @idempotency_key,
          status: :running,
          evidence: {},
          started_at: Time.current
        )
        deployment = Deployments::Transition.call(
          deployment: @deployment,
          to: :building,
          actor: nil,
          cause: "build_started",
          expected_lock_version: @deployment.lock_version
        ).deployment

        Result.new(build:, deployment:, replayed: false)
      end
    end
  end
end
