module Api
  module V1
    class BaseController < ApplicationController
      protect_from_forgery with: :null_session

      before_action :assign_correlation_id
      before_action :authenticate_principal!
      before_action :select_organization!

      rescue_from ActiveRecord::RecordInvalid, with: :render_invalid_record
      rescue_from Api::Idempotency::Execute::MissingKey, with: :render_missing_idempotency_key
      rescue_from Api::Idempotency::Execute::InvalidKey, with: :render_invalid_idempotency_key
      rescue_from Api::Idempotency::Execute::Conflict, with: :render_idempotency_conflict
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

      private

      def current_principal
        principal = request.env["lrail.authenticated_principal"]
        principal if principal.is_a?(User) && principal.persisted?
      end

      def current_organization
        @current_organization
      end

      def assign_correlation_id
        @correlation_id = SecureRandom.uuid_v7
        response.set_header("X-Correlation-Id", @correlation_id)
      end

      def authenticate_principal!
        return if current_principal

        render_error(:unauthorized, "unauthenticated", "Authentication is required")
      end

      def select_organization!
        return if performed?

        @current_organization = Organization.find_by(id: params[:organization_id])
        membership_exists = @current_organization && Membership.exists?(
          user_id: current_principal.id,
          organization_id: @current_organization.id
        )
        return if membership_exists

        @current_organization = nil

        render_error(:not_found, "organization_not_found", "Organization was not found")
      end

      def render_invalid_record(error)
        render_error(
          :unprocessable_content,
          "validation_failed",
          "The request could not be validated",
          fields: error.record.errors.to_hash
        )
      end

      def render_forbidden
        render_error(:forbidden, "forbidden", "You are not allowed to perform this action")
      end

      def render_missing_idempotency_key
        render_error(:bad_request, "idempotency_key_required", "Idempotency-Key is required")
      end

      def render_invalid_idempotency_key
        render_error(:bad_request, "idempotency_key_invalid", "Idempotency-Key is invalid")
      end

      def render_idempotency_conflict
        render_error(
          :conflict,
          "idempotency_key_conflict",
          "Idempotency-Key was already used for a different request"
        )
      end

      def render_error(status, code, message, details = nil)
        payload = {
          code:,
          message:,
          correlation_id: @correlation_id
        }
        payload[:details] = details if details

        render json: payload, status:
      end
    end
  end
end
