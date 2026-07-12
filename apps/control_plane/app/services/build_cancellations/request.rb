module BuildCancellations
  class Request
    class InvalidDeployment < StandardError; end
    class StaleDeployment < StandardError; end

    Result = Data.define(:deployment, :build, :command, :replayed)

    def self.call(deployment:, operation_id:, expected_lock_version:)
      new(deployment:, operation_id:, expected_lock_version:).call
    end

    def initialize(deployment:, operation_id:, expected_lock_version:)
      @deployment = deployment
      @operation_id = operation_id.to_s
      @expected_lock_version = expected_lock_version
    end

    def call
      validate!
      ApplicationRecord.transaction(requires_new: true) do
        @deployment.lock!
        if @deployment.status == "canceled"
          return Result.new(deployment: @deployment, build: nil, command: nil, replayed: true)
        end
        raise StaleDeployment unless @deployment.lock_version == @expected_lock_version
        raise InvalidDeployment unless @deployment.status == "canceling"

        build = @deployment.builds.order(:attempt).last
        unless build&.status == "running"
          deployment = Deployments::Transition.call(
            deployment: @deployment,
            to: :canceled,
            actor: nil,
            cause: "build_not_started",
            expected_lock_version: @deployment.lock_version
          ).deployment
          return Result.new(deployment:, build:, command: nil, replayed: false)
        end

        command = OutboxEvents::Publish.call(
          organization: @deployment.organization,
          resource_id: build.id,
          event_type: "build.cancellation.requested.v1",
          correlation_id: @deployment.correlation_id,
          idempotency_key: "build:#{build.id}:cancel",
          producer: "control-plane",
          data: {
            "contract_version" => 1,
            "command_type" => "build.cancel",
            "operation_id" => @operation_id,
            "organization_id" => @deployment.organization_id,
            "deployment_id" => @deployment.id,
            "build_id" => build.id,
            "expected_version" => @deployment.lock_version
          }
        ).event

        Result.new(deployment: @deployment, build:, command:, replayed: false)
      end
    end

    private

    def validate!
      raise InvalidDeployment unless Events::Envelope::UUID_PATTERN.match?(@operation_id)
      raise InvalidDeployment unless @expected_lock_version.is_a?(Integer)
      event = OutboxEvent.find_by(
        id: @operation_id,
        organization_id: @deployment.organization_id,
        resource_id: @deployment.id,
        event_type: "deployment.cancellation.requested.v1"
      )
      raise InvalidDeployment unless event
      raise InvalidDeployment unless event.data["expected_version"] == @expected_lock_version
    end
  end
end
