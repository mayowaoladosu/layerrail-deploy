module Internal
  module V1
    class OrchestratorBaseController < ActionController::API
      before_action :authenticate_orchestrator!
      before_action :require_temporal_mode!

      private

      def authenticate_orchestrator!
        return if Orchestrator::RequestAuthentication.valid?(request:)

        render json: { code: "unauthorized", message: "Orchestrator authentication failed" }, status: :unauthorized
      end

      def require_temporal_mode!
        return if Orchestrator::Mode.temporal?

        render json: { code: "orchestrator_disabled", message: "Temporal orchestration is disabled" }, status: :conflict
      end

      def render_invalid_request(message)
        render json: { code: "invalid_request", message: }, status: :unprocessable_content
      end
    end
  end
end
