module Internal
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_local_provider!

      private

      def authenticate_local_provider!
        return if LocalProvider::RequestAuthentication.valid?(request:)

        render json: { code: "unauthorized", message: "Provider authentication failed" }, status: :unauthorized
      end

      def render_invalid_request(message)
        render json: { code: "invalid_request", message: }, status: :unprocessable_content
      end
    end
  end
end
