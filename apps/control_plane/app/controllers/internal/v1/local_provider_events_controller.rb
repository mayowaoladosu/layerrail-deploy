module Internal
  module V1
    class LocalProviderEventsController < BaseController
      rescue_from LocalProviderEvents::Consume::InvalidEvent, with: :render_invalid_event
      rescue_from EventConsumers::Process::Conflict, with: :render_event_conflict

      def create
        envelope = JSON.parse(request.raw_post)
        result = LocalProviderEvents::Consume.call(envelope:)
        render json: { result: result.result, replayed: result.replayed }, status: :ok
      rescue JSON::ParserError
        render_invalid_event
      end

      private

      def render_invalid_event
        render json: { code: "invalid_event", message: "Provider event is invalid" }, status: :unprocessable_content
      end

      def render_event_conflict
        render json: { code: "event_conflict", message: "Provider event conflicts with its receipt" }, status: :conflict
      end
    end
  end
end
