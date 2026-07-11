module Deployments
  class Transition
    class InvalidTransition < StandardError; end
    class StaleTransition < StandardError; end

    Result = Data.define(:deployment, :transition)

    TRANSITIONS = {
      "created" => %w[queued canceling failed],
      "queued" => %w[preparing canceling failed],
      "preparing" => %w[building canceling failed],
      "building" => %w[preparing scanning canceling failed],
      "scanning" => %w[deploying canceling failed],
      "deploying" => %w[verifying canceling failed],
      "verifying" => %w[ready canceling failed],
      "ready" => %w[promoted superseded canceling failed],
      "promoted" => %w[superseded canceling failed],
      "canceling" => %w[canceled failed],
      "superseded" => %w[promoted canceling],
      "canceled" => [],
      "failed" => []
    }.freeze

    def self.call(deployment:, to:, actor:, cause:, expected_lock_version:, error: {})
      new(
        deployment:,
        to:,
        actor:,
        cause:,
        expected_lock_version:,
        error:
      ).call
    end

    def initialize(deployment:, to:, actor:, cause:, expected_lock_version:, error:)
      @deployment = deployment
      @to = to.to_s
      @actor = actor
      @cause = cause.to_s
      @expected_lock_version = expected_lock_version
      @error = error
    end

    def call
      transition = nil
      @deployment.with_lock do
        raise StaleTransition unless @deployment.lock_version == @expected_lock_version
        raise InvalidTransition unless TRANSITIONS.fetch(@deployment.status).include?(@to)

        from = @deployment.status
        @deployment.status = @to
        @deployment.conclusion = conclusion_for(@to)
        @deployment.save!
        transition = @deployment.deployment_transitions.create!(
          correlation_id: @deployment.correlation_id,
          sequence: @deployment.deployment_transitions.maximum(:sequence).to_i + 1,
          from_status: from,
          to_status: @to,
          actor_type: @actor ? "user" : "system",
          actor_id: @actor&.id,
          cause: @cause,
          error: @error,
          occurred_at: Time.current
        )
        Deployments::PublishTransition.call(deployment: @deployment, transition:)
      end

      Result.new(deployment: @deployment, transition:)
    end

    private

    def conclusion_for(status)
      {
        "ready" => "succeeded",
        "promoted" => "succeeded",
        "superseded" => "succeeded",
        "failed" => "failed",
        "canceled" => "canceled"
      }[status]
    end
  end
end
