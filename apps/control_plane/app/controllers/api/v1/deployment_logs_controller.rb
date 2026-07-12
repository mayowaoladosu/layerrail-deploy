module Api
  module V1
    class DeploymentLogsController < BaseController
      rescue_from DeploymentLogs::Feed::InvalidCursor, with: :render_invalid_cursor

      def index
        deployment = Deployment.find_by(
          id: params[:deployment_id],
          organization_id: current_organization.id
        )
        return render_not_found unless deployment

        authorize deployment, :show?
        provider_result = LocalProvider::LogClient.fetch(
          organization_id: deployment.organization_id,
          deployment_id: deployment.id
        )
        feed = DeploymentLogs::Feed.call(
          deployment:,
          provider_result:,
          cursor: params[:cursor],
          limit: requested_limit
        )
        response.set_header("X-Lrail-Logs-Partial", "true") unless feed.provider_status == :ok
        render json: {
          data: feed.entries.map { |entry| serialize_entry(entry) },
          page: { next_cursor: feed.next_cursor }
        }, status: :ok
      rescue ArgumentError
        render_validation_error(:limit, "must be an integer from 1 to 100")
      end

      private

      def organization_id_from_request
        Deployment.where(id: params[:deployment_id]).pick(:organization_id)
      end

      def requested_limit
        Integer(params.fetch(:limit, 25).to_s, 10).tap do |limit|
          raise ArgumentError unless limit.between?(1, 100)
        end
      end

      def serialize_entry(entry)
        {
          timestamp: entry.timestamp.utc.iso8601(6),
          stream: entry.stream,
          level: entry.level,
          message: entry.message
        }
      end

      def render_invalid_cursor
        render_validation_error(:cursor, "is invalid or expired")
      end
    end
  end
end
