module Builds
  class Cancel
    class InvalidBuildState < StandardError; end
    class InvalidDeploymentState < StandardError; end

    Result = Data.define(:build, :deployment, :replayed)

    def self.call(build:)
      new(build:).call
    end

    def initialize(build:)
      @build = build
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @build.lock!
        if @build.status == "canceled"
          return Result.new(build: @build, deployment: @build.deployment, replayed: true)
        end
        raise InvalidBuildState unless @build.status == "running"

        deployment = @build.deployment
        raise InvalidDeploymentState unless deployment.status == "canceling"

        @build.update!(status: :canceled, evidence: {}, finished_at: Time.current)
        deployment = Deployments::Transition.call(
          deployment:,
          to: :canceled,
          actor: nil,
          cause: "build_canceled",
          expected_lock_version: deployment.lock_version
        ).deployment

        Result.new(build: @build, deployment:, replayed: false)
      end
    end
  end
end
