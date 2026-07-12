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
      rescue_from ActionController::ParameterMissing, with: :render_missing_parameter
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

      private

      def current_principal
        injected = request.env["lrail.authenticated_principal"]
        return injected if Rails.env.test? && injected.is_a?(User) && injected.persisted?
        return unless rodauth.valid_jwt? && rodauth.logged_in?

        account = rodauth.rails_account
        account if account.is_a?(User) && account.persisted?
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

        @current_organization = Organization.find_by(id: organization_id_from_request)
        membership_exists = @current_organization && Membership.exists?(
          user_id: current_principal.id,
          organization_id: @current_organization.id
        )
        return if membership_exists

        @current_organization = nil

        render_error(:not_found, "organization_not_found", "Organization was not found")
      end

      def organization_id_from_request
        params[:organization_id]
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

      def render_not_found
        render_error(:not_found, "not_found", "The requested resource was not found")
      end

      def render_validation_error(field, message)
        render_error(
          :unprocessable_content,
          "validation_failed",
          "The request could not be validated",
          fields: { field.to_s => [ message ] }
        )
      end

      def render_conflict(code, message)
        render_error(:conflict, code, message)
      end

      def render_missing_parameter(error)
        render_validation_error(error.param, "is required")
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

      def serialize_deployment(deployment)
        revision = deployment.revisions.where(status: "ready").order(:created_at, :id).last
        {
          id: deployment.id,
          organization_id: deployment.organization_id,
          service_id: deployment.service_id,
          environment_id: deployment.environment_id,
          revision_id: revision&.id,
          status: deployment.status,
          source: deployment.source_snapshot,
          preview_url: "#{ENV.fetch("CONTROL_PLANE_SCHEME", "http")}://#{Routing::Hostnames.immutable(deployment)}",
          created_at: deployment.created_at.iso8601(6),
          updated_at: deployment.updated_at.iso8601(6)
        }
      end

      def serialize_operation(event)
        {
          id: event.id,
          organization_id: event.organization_id,
          resource_id: event.resource_id,
          status: operation_status(event.status),
          correlation_id: event.correlation_id,
          created_at: event.created_at.iso8601(6)
        }
      end

      def render_mutation(mutation)
        response.set_header("Idempotency-Replayed", "true") if mutation.replayed
        render json: mutation.body, status: mutation.status
      end

      def operation_status(status)
        {
          "pending" => "pending",
          "delivering" => "running",
          "published" => "succeeded",
          "dead" => "failed"
        }.fetch(status)
      end
    end
  end
end
