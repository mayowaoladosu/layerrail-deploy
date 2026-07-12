module Internal
  module V1
    class BuildControllerEventsController < BuildControllerBaseController
      rescue_from BuildEvents::Consume::InvalidEvent, with: :render_invalid_event
      rescue_from EventConsumers::Process::Conflict, with: :render_event_conflict
      rescue_from Builds::Complete::CompletionConflict, with: :render_event_conflict
      rescue_from Builds::Complete::EvidenceRejected, with: :render_invalid_event

      def create
        envelope = JSON.parse(request.raw_post)
        result = BuildEvents::Consume.call(envelope:)
        render json: { result: result.result, replayed: result.replayed }, status: :ok
      rescue JSON::ParserError
        render_invalid_event
      end

      private

      def render_invalid_event
        render json: { code: "invalid_event", message: "Build event is invalid" }, status: :unprocessable_content
      end

      def render_event_conflict
        render json: { code: "event_conflict", message: "Build event conflicts with its receipt" }, status: :conflict
      end
    end
  end
end
