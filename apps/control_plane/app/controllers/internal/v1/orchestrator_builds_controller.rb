module Internal
  module V1
    class OrchestratorBuildsController < OrchestratorBaseController
      PREPARE_KEYS = %w[
        contract_version event_id organization_id deployment_id service_id
        environment_id configuration_snapshot_id source_digest workload_type
        expected_version operation_id
      ].freeze
      CANCEL_KEYS = %w[
        contract_version event_id operation_id organization_id deployment_id
        expected_version message_type transition_id
      ].freeze

      rescue_from Builds::Prepare::InvalidDeployment, with: :render_invalid_build
      rescue_from Builds::Prepare::StaleDeployment, with: :render_stale_build
      rescue_from BuildCancellations::Request::InvalidDeployment, with: :render_invalid_build
      rescue_from BuildCancellations::Request::StaleDeployment, with: :render_stale_build

      def prepare
        value = JSON.parse(request.raw_post)
        return render_invalid_request("Invalid build preparation") unless valid_prepare?(value)

        deployment = Deployment.find_by(
          id: value.fetch("deployment_id"),
          organization_id: value.fetch("organization_id")
        )
        return render json: { code: "not_found", message: "Deployment was not found" }, status: :not_found unless deployment
        return render_invalid_request("Invalid build preparation") unless deployment.service_id == value.fetch("service_id")
        return render_invalid_request("Invalid build preparation") unless deployment.environment_id == value.fetch("environment_id")
        return render_invalid_request("Invalid build preparation") unless deployment.configuration_snapshot_id == value.fetch("configuration_snapshot_id")
        return render_invalid_request("Invalid build preparation") unless "sha256:#{deployment.source_digest}" == value.fetch("source_digest")
        return render_invalid_request("Invalid build preparation") unless deployment.build_settings_snapshot["workload_type"] == value.fetch("workload_type")

        result = Builds::Prepare.call(
          deployment:,
          operation_id: value.fetch("operation_id"),
          expected_lock_version: value.fetch("expected_version")
        )
        render json: {
          contract_version: 1,
          operation_id: value.fetch("operation_id"),
          organization_id: deployment.organization_id,
          deployment_id: deployment.id,
          accepted: true,
          stale: false,
          current_version: result.current_version,
          deployment_status: result.deployment_status,
          build_id: result.build.id,
          revision_id: result.revision_id
        }, status: :ok
      rescue JSON::ParserError
        render_invalid_request("Invalid build preparation")
      end

      def cancel
        value = JSON.parse(request.raw_post)
        return render_invalid_request("Invalid build cancellation") unless valid_cancel?(value)

        deployment = Deployment.find_by(
          id: value.fetch("deployment_id"),
          organization_id: value.fetch("organization_id")
        )
        return render json: { code: "not_found", message: "Deployment was not found" }, status: :not_found unless deployment

        result = BuildCancellations::Request.call(
          deployment:,
          operation_id: value.fetch("event_id"),
          expected_lock_version: value.fetch("expected_version")
        )
        render json: {
          operation_id: value.fetch("operation_id"),
          accepted: true,
          stale: false,
          current_version: result.deployment.lock_version,
          deployment_status: result.deployment.status
        }, status: :ok
      rescue JSON::ParserError
        render_invalid_request("Invalid build cancellation")
      end

      private

      def valid_prepare?(value)
        value.is_a?(Hash) &&
          value.keys.sort == PREPARE_KEYS.sort &&
          value["contract_version"] == 1 &&
          value["expected_version"].is_a?(Integer) &&
          value["workload_type"].in?(%w[web static]) &&
          value["source_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) &&
          %w[event_id operation_id organization_id deployment_id service_id environment_id configuration_snapshot_id].all? do |key|
            Events::Envelope::UUID_PATTERN.match?(value[key].to_s)
          end
      end

      def valid_cancel?(value)
        value.is_a?(Hash) &&
          value.keys.sort == CANCEL_KEYS.sort &&
          value["contract_version"] == 1 &&
          value["message_type"] == "deployment.cancel" &&
          value["expected_version"].is_a?(Integer) &&
          %w[event_id operation_id organization_id deployment_id transition_id].all? do |key|
            Events::Envelope::UUID_PATTERN.match?(value[key].to_s)
          end
      end

      def render_invalid_build
        render_invalid_request("Build request is invalid")
      end

      def render_stale_build
        render json: { code: "stale_build", message: "Deployment version is stale" }, status: :conflict
      end
    end
  end
end
