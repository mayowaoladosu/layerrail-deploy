module Deployments
  class PublishCancellation
    def self.call(deployment:, transition:)
      OutboxEvents::Publish.call(
        organization: deployment.organization,
        resource_id: deployment.id,
        event_type: "deployment.cancellation.requested.v1",
        correlation_id: deployment.correlation_id,
        idempotency_key: "deployment:#{deployment.id}:cancellation:#{transition.sequence}",
        producer: "control-plane",
        data: {
          "deployment_id" => deployment.id,
          "transition_id" => transition.id,
          "expected_version" => deployment.lock_version
        }
      )
    end
  end
end
