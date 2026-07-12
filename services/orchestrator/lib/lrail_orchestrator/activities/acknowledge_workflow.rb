# frozen_string_literal: true

require "temporalio/activity"

module LrailOrchestrator
  module Activities
    class AcknowledgeWorkflow < Temporalio::Activity::Definition
      activity_name "lrail.workflow.acknowledge.v1"

      def initialize(control_plane)
        @control_plane = control_plane
      end

      def execute(value)
        operation = Contracts.workflow_operation_message(value)
        Contracts.operation_result(@control_plane.observe(operation))
      end
    end
  end
end
