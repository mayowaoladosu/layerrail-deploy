module Webhooks
  class GithubController < ActionController::Base
    protect_from_forgery with: :null_session

    def create
      result = GitWebhooks::Ingest.call(
        provider: git_provider,
        provider_name: :github,
        delivery_id: request.headers["X-GitHub-Delivery"],
        event_type: request.headers["X-GitHub-Event"],
        signature: request.headers["X-Hub-Signature-256"],
        body: request.raw_post
      )

      return render_failure(result.error) if result.failure?

      status = if result.value.ignored
        "ignored"
      elsif result.value.replayed
        "replayed"
      else
        "accepted"
      end
      render json: { status: }, status: :accepted
    rescue KeyError, OpenSSL::PKey::PKeyError
      render json: { code: "provider_not_configured" }, status: :service_unavailable
    end

    private

    def git_provider
      request.env["lrail.git_provider"] || GitProviders::Factory.github
    end

    def render_failure(error)
      status = {
        delivery_conflict: :conflict,
        invalid_payload: :bad_request,
        invalid_signature: :unauthorized,
        payload_too_large: :content_too_large,
        unsupported_event: :accepted
      }.fetch(error.code, :bad_request)

      render json: { code: error.code.to_s, message: error.message }, status:
    end
  end
end
