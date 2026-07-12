module Internal
  module V1
    class BuildControllerCommandsController < BuildControllerBaseController
      SUPPORTED_EVENT_TYPES = %w[
        build.requested.v1
        build.cancellation.requested.v1
      ].freeze
      LEASE_DURATION = 5.minutes

      rescue_from OutboxEvents::Claim::InvalidRequest, with: :render_claim_invalid
      rescue_from OutboxEvents::Finalize::StaleClaim, with: :render_stale_claim
      rescue_from OutboxEvents::Finalize::OutcomeConflict, with: :render_outcome_conflict

      def claim
        requested_types = Array(params[:event_types]).map(&:to_s).uniq
        unless requested_types.present? && (requested_types - SUPPORTED_EVENT_TYPES).empty?
          return render_invalid_request("Unsupported event types")
        end

        result = OutboxEvents::Claim.call(
          request_id: request.headers["X-Lrail-Request-Id"],
          event_types: requested_types,
          now: Time.current,
          lease_duration: LEASE_DURATION
        )
        return head :no_content unless result

        render json: {
          event: result.event.envelope,
          claim_token: result.claim_token,
          lease_expires_at: result.event.locked_until.iso8601(6)
        }, status: :ok
      end

      def finalize
        event = OutboxEvent.find_by(id: params[:event_id], event_type: SUPPORTED_EVENT_TYPES)
        return render json: { code: "not_found", message: "Build command was not found" }, status: :not_found unless event

        result = OutboxEvents::Finalize.call(
          event:,
          claim_token: params[:claim_token],
          outcome: delivery_result,
          now: Time.current
        )
        render json: { status: result.status, replayed: result.replayed }, status: :ok
      rescue ArgumentError
        render_invalid_request("Invalid delivery outcome")
      end

      private

      def delivery_result
        case params[:outcome]
        when "published"
          OutboxEvents::DeliveryResult.published
        when "retry"
          OutboxEvents::DeliveryResult.retry(params[:safe_error])
        when "rejected"
          OutboxEvents::DeliveryResult.rejected(params[:safe_error])
        else
          raise ArgumentError
        end
      end

      def render_claim_invalid
        render_invalid_request("Invalid claim request")
      end

      def render_stale_claim
        render json: { code: "stale_claim", message: "Build command lease is no longer active" }, status: :conflict
      end

      def render_outcome_conflict
        render json: { code: "outcome_conflict", message: "Build command already has another outcome" }, status: :conflict
      end
    end
  end
end
