module Internal
  module V1
    class OrchestratorOperationsController < OrchestratorBaseController
      KEYS = %w[
        contract_version operation_id organization_id deployment_id
        expected_version stage
      ].freeze

      def create
        value = JSON.parse(request.raw_post)
        return render_invalid_request("Invalid workflow operation") unless valid?(value)

        deployment = Deployment.find_by(
          id: value.fetch("deployment_id"),
          organization_id: value.fetch("organization_id")
        )
        return render json: { code: "not_found", message: "Deployment was not found" }, status: :not_found unless deployment

        stale = deployment.lock_version != value.fetch("expected_version")
        render json: {
          operation_id: value.fetch("operation_id"),
          accepted: !stale,
          stale:,
          current_version: deployment.lock_version,
          deployment_status: deployment.status
        }, status: :ok
      rescue JSON::ParserError
        render_invalid_request("Invalid workflow operation")
      end

      private

      def valid?(value)
        value.is_a?(Hash) &&
          request.raw_post.bytesize <= Events::Envelope::MAX_DATA_BYTES &&
          value.keys.sort == KEYS.sort &&
          value["contract_version"] == 1 &&
          value["stage"] == "workflow_accepted" &&
          value["expected_version"].is_a?(Integer) &&
          value["expected_version"].between?(0, 2_147_483_647) &&
          %w[operation_id organization_id deployment_id].all? do |key|
            Events::Envelope::UUID_PATTERN.match?(value[key].to_s)
          end
      end
    end
  end
end
