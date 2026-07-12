module Internal
  module V1
    class BuildControllerBaseController < ActionController::API
      before_action :authenticate_build_controller!
      before_action :require_temporal_mode!

      private

      def authenticate_build_controller!
        return if Orchestrator::RequestAuthentication.valid?(request:)

        render json: { code: "unauthorized", message: "Build controller authentication failed" }, status: :unauthorized
      end

      def require_temporal_mode!
        return if Orchestrator::Mode.temporal?

        render json: { code: "build_controller_disabled", message: "Build controller delivery is disabled" }, status: :conflict
      end

      def render_invalid_request(message)
        render json: { code: "invalid_request", message: }, status: :unprocessable_content
      end
    end
  end
end
