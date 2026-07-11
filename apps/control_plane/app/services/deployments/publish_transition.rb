module Deployments
  class PublishTransition
    def self.call(deployment:, transition:)
      OutboxEvents::Publish.call(
        organization: deployment.organization,
        resource_id: deployment.id,
        event_type: "deployment.transitioned.v1",
        correlation_id: deployment.correlation_id,
        idempotency_key: "deployment:#{deployment.id}:transition:#{transition.sequence}",
        producer: "control-plane",
        data: {
          "deployment_id" => deployment.id,
          "transition_id" => transition.id,
          "sequence" => transition.sequence,
          "from_status" => transition.from_status,
          "to_status" => transition.to_status,
          "cause" => transition.cause,
          "actor_type" => transition.actor_type,
          "expected_version" => deployment.lock_version,
          "error" => transition.error
        }
      )
    end
  end
end
