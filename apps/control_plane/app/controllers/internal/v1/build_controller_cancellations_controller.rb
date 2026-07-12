module Internal
  module V1
    class BuildControllerCancellationsController < BuildControllerBaseController
      KEYS = %w[
        contract_version operation_id organization_id deployment_id build_id
        expected_version evidence
      ].freeze

      rescue_from BuildCancellations::Complete::InvalidCommand, with: :render_invalid_cancellation
      rescue_from BuildCancellations::Complete::StaleDeployment, with: :render_stale_cancellation

      def create
        value = JSON.parse(request.raw_post)
        return render_invalid_request("Invalid build cancellation") unless valid?(value)

        build = Build.find_by(
          id: value.fetch("build_id"),
          organization_id: value.fetch("organization_id"),
          deployment_id: value.fetch("deployment_id")
        )
        return render json: { code: "not_found", message: "Build was not found" }, status: :not_found unless build

        result = BuildCancellations::Complete.call(
          build:,
          operation_id: value.fetch("operation_id"),
          expected_lock_version: value.fetch("expected_version"),
          evidence: value.fetch("evidence")
        )
        render json: {
          build_id: result.build.id,
          deployment_id: result.deployment.id,
          current_version: result.deployment.lock_version,
          deployment_status: result.deployment.status,
          replayed: result.replayed
        }, status: :ok
      rescue JSON::ParserError
        render_invalid_request("Invalid build cancellation")
      end

      private

      def valid?(value)
        value.is_a?(Hash) &&
          value.keys.sort == KEYS.sort &&
          value["contract_version"] == 1 &&
          value["expected_version"].is_a?(Integer) &&
          value["evidence"].is_a?(Hash) &&
          value["evidence"].to_json.bytesize <= 32.kilobytes &&
          %w[operation_id organization_id deployment_id build_id].all? do |key|
            Events::Envelope::UUID_PATTERN.match?(value[key].to_s)
          end
      end

      def render_invalid_cancellation
        render_invalid_request("Build cancellation is invalid")
      end

      def render_stale_cancellation
        render json: { code: "stale_build", message: "Deployment version is stale" }, status: :conflict
      end
    end
  end
end
