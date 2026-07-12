module Deployments
  class Cancel
    class InUse < StandardError; end

    Result = Data.define(:deployment, :transition, :event)

    def self.call(context:, deployment:, expected_lock_version:)
      new(context:, deployment:, expected_lock_version:).call
    end

    def initialize(context:, deployment:, expected_lock_version:)
      @context = context
      @deployment = deployment
      @expected_lock_version = expected_lock_version
    end

    def call
      authorize!
      ApplicationRecord.transaction(requires_new: true) do
        @deployment.lock!
        raise InUse if serving_alias?

        transitioned = Deployments::Transition.call(
          deployment: @deployment,
          to: :canceling,
          actor: @context.principal,
          cause: "cancellation_requested",
          expected_lock_version: @expected_lock_version
        )
        Result.new(
          deployment: transitioned.deployment,
          transition: transitioned.transition,
          event: transitioned.event
        )
      end
    end

    private

    def authorize!
      return if DeploymentPolicy.new(@context, @deployment).transition?

      raise Pundit::NotAuthorizedError, "not allowed to cancel this deployment"
    end

    def serving_alias?
      Alias.joins(:current_revision).exists?(revisions: { deployment_id: @deployment.id })
    end
  end
end
