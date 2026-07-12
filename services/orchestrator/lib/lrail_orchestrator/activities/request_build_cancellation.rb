# frozen_string_literal: true

require "temporalio/activity"

module LrailOrchestrator
  module Activities
    class RequestBuildCancellation < Temporalio::Activity::Definition
      activity_name "lrail.build.cancel.v1"

      def initialize(control_plane)
        @control_plane = control_plane
      end

      def execute(value)
        signal = Contracts.cancellation_workflow_signal(value)
        Contracts.operation_result(@control_plane.cancel_build(signal))
      end
    end
  end
end
