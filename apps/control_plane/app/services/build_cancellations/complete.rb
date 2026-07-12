module BuildCancellations
  class Complete
    class InvalidCommand < StandardError; end
    class StaleDeployment < StandardError; end

    Result = Data.define(:build, :deployment, :replayed)

    def self.call(build:, operation_id:, expected_lock_version:, evidence: {})
      new(build:, operation_id:, expected_lock_version:, evidence:).call
    end

    def initialize(build:, operation_id:, expected_lock_version:, evidence:)
      @build = build
      @operation_id = operation_id.to_s
      @expected_lock_version = expected_lock_version
      @evidence = JSON.parse(JSON.generate(evidence))
    end

    def call
      validate!
      deployment = @build.deployment
      if @build.status == "canceled"
        raise InvalidCommand unless @build.evidence == @evidence

        return Result.new(build: @build, deployment:, replayed: true)
      end
      raise StaleDeployment unless deployment.lock_version == @expected_lock_version

      result = Builds::Cancel.call(build: @build, evidence: @evidence)
      Result.new(build: result.build, deployment: result.deployment, replayed: result.replayed)
    end

    private

    def validate!
      deployment = @build.deployment
      command = OutboxEvent.find_by(
        organization_id: deployment.organization_id,
        resource_id: @build.id,
        event_type: "build.cancellation.requested.v1"
      )
      raise InvalidCommand unless command
      raise InvalidCommand unless command.data["operation_id"] == @operation_id
      raise InvalidCommand unless command.data["expected_version"] == @expected_lock_version
      raise InvalidCommand unless deployment.status.in?(%w[canceling canceled])
    end
  end
end
