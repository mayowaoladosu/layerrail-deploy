module Internal
  module V1
    class BuildControllerCredentialsController < BuildControllerBaseController
      rescue_from Builds::CloneCredentials::InvalidBuild, with: :render_invalid_build
      rescue_from Builds::CloneCredentials::ProviderFailure, with: :render_provider_failure

      def show
        build = Build.find_by(id: params[:build_id])
        return render json: { code: "not_found", message: "Build was not found" }, status: :not_found unless build

        result = Builds::CloneCredentials.call(
          build:,
          operation_id: params[:operation_id]
        )
        credentials = result.credentials
        response.set_header("Cache-Control", "no-store")
        render json: {
          contract_version: 1,
          build_id: build.id,
          clone_url: credentials.clone_url.to_s,
          username: credentials.username,
          secret: credentials.secret,
          expires_at: credentials.expires_at.iso8601(6)
        }, status: :ok
      end

      private

      def render_invalid_build
        render_invalid_request("Build credential request is invalid")
      end

      def render_provider_failure(error)
        response.set_header("Retry-After", "30") if error.retryable
        render json: {
          code: error.code,
          message: "Git provider could not issue clone credentials",
          retryable: error.retryable
        }, status: error.retryable ? :service_unavailable : :unprocessable_content
      end
    end
  end
end
