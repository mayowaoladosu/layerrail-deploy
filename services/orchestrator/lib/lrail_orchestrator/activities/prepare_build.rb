# frozen_string_literal: true

require "temporalio/activity"

module LrailOrchestrator
  module Activities
    class PrepareBuild < Temporalio::Activity::Definition
      activity_name "lrail.build.prepare.v1"

      def initialize(control_plane)
        @control_plane = control_plane
      end

      def execute(value)
        input = Contracts.deployment_workflow_input(value)
        Contracts.build_prepared(@control_plane.prepare_build(input))
      end
    end
  end
end
