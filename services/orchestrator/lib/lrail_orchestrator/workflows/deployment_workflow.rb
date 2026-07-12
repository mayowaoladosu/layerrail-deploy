# frozen_string_literal: true

require "temporalio/error"
require "temporalio/retry_policy"
require "temporalio/workflow"

module LrailOrchestrator
  module Workflows
    class DeploymentWorkflow < Temporalio::Workflow::Definition
      workflow_name "lrail.deployment.v1"

      def execute(raw_input)
        @input = Contracts.deployment_workflow_input(raw_input)
        @expected_version = @input.fetch("expected_version")
        @state = "acknowledging"
        @seen_signals = {}
        @ignored_signal_count = 0
        @invalid_signal = false
        @signal_conflict = false

        acknowledgement = acknowledge
        if acknowledgement.fetch("stale")
          @expected_version = acknowledgement.fetch("current_version")
          @state = "stale"
          return result("stale_observed")
        end

        return terminal_result if terminal_signal?

        prepared = prepare_build
        @build_id = prepared.fetch("build_id")
        @revision_id = prepared.fetch("revision_id")
        @build_expected_version = prepared.fetch("current_version")
        @expected_version = [ @expected_version, @build_expected_version ].max
        validate_queued_signal(:build)
        return terminal_result if terminal_signal?

        @state = "awaiting_build"
        Temporalio::Workflow.wait_condition { terminal_signal? || @build_signal }
        return terminal_result if terminal_signal?
        if @build_signal.fetch("status") == "failed"
          @state = "failed"
          return result(
            "failed_observed",
            "failure_code" => @build_signal.fetch("failure_code")
          )
        end

        @artifact_digest = @build_signal.fetch("artifact_digest")
        validate_queued_signal(:release)
        if @release_signal &&
            @release_signal.fetch("expected_version") < @build_signal.fetch("expected_version")
          @release_signal = nil
          ignore_signal
        end
        @state = "awaiting_release"
        Temporalio::Workflow.wait_condition { terminal_signal? || @release_signal }
        return terminal_result if terminal_signal?

        case @release_signal.fetch("status")
        when "ready"
          @state = "ready_observed"
          result(
            "ready_observed",
            "build_id" => @build_id,
            "revision_id" => @revision_id,
            "artifact_digest" => @artifact_digest
          )
        when "failed"
          @state = "failed"
          result(
            "failed_observed",
            "failure_code" => @release_signal.fetch("failure_code")
          )
        else
          @state = "canceled"
          result("canceled_observed")
        end
      rescue Temporalio::Error::ActivityError
        @state = "failed"
        result("failed_observed", "failure_code" => "workflow_activity_failed")
      end

      workflow_signal
      def build_completed(value)
        signal = Contracts.build_workflow_signal(value)
        accept_signal(:build, signal)
      rescue Contracts::Invalid
        @invalid_signal = true
      end

      workflow_signal
      def release_reconciled(value)
        signal = Contracts.release_workflow_signal(value)
        accept_signal(:release, signal)
      rescue Contracts::Invalid
        @invalid_signal = true
      end

      workflow_signal
      def cancellation_requested(value)
        signal = Contracts.cancellation_workflow_signal(value)
        accept_signal(:cancellation, signal)
      rescue Contracts::Invalid
        @invalid_signal = true
      end

      workflow_query
      def orchestration_state
        {
          "contract_version" => 1,
          "deployment_id" => @input&.fetch("deployment_id", nil),
          "state" => @state || "initializing",
          "expected_version" => @expected_version || 0,
          "ignored_signal_count" => @ignored_signal_count || 0
        }
      end

      private

      def acknowledge
        Temporalio::Workflow.execute_activity(
          Activities::AcknowledgeWorkflow,
          Contracts.workflow_operation(@input),
          activity_id: "ack/#{@input.fetch("operation_id")}",
          schedule_to_close_timeout: 60,
          start_to_close_timeout: 10,
          retry_policy: Temporalio::RetryPolicy.new(
            initial_interval: 1,
            backoff_coefficient: 2.0,
            max_interval: 10,
            max_attempts: 5
          )
        )
      end

      def prepare_build
        @state = "preparing_build"
        Temporalio::Workflow.execute_activity(
          Activities::PrepareBuild,
          @input,
          activity_id: "build/prepare/#{@input.fetch("operation_id")}",
          schedule_to_close_timeout: 120,
          start_to_close_timeout: 30,
          retry_policy: Temporalio::RetryPolicy.new(
            initial_interval: 1,
            backoff_coefficient: 2.0,
            max_interval: 15,
            max_attempts: 5
          )
        )
      end

      def accept_signal(slot, signal)
        return ignore_signal if signal.fetch("deployment_id") != @input.fetch("deployment_id")
        return ignore_signal if signal.fetch("organization_id") != @input.fetch("organization_id")
        event_id = signal.fetch("event_id")
        if @seen_signals.key?(event_id)
          @signal_conflict = true unless @seen_signals.fetch(event_id) == signal
          return
        end
        return ignore_signal if signal.fetch("expected_version") < minimum_version_for(slot)
        return ignore_signal unless signal_identity_matches?(slot, signal)

        current = instance_variable_get("@#{slot}_signal")
        if current
          @signal_conflict = true
          return
        end

        @expected_version = [ @expected_version, signal.fetch("expected_version") ].max
        @seen_signals[event_id] = signal
        instance_variable_set("@#{slot}_signal", signal)
      end

      def signal_identity_matches?(slot, signal)
        case slot
        when :build
          return true unless @build_id

          signal.fetch("operation_id") == @input.fetch("operation_id") &&
            signal.fetch("build_id") == @build_id
        when :release
          return true unless signal.fetch("status") == "ready"
          return true unless @revision_id && @artifact_digest

          signal.fetch("revision_id") == @revision_id &&
            signal.fetch("artifact_digest") == @artifact_digest
        else
          true
        end
      end

      def validate_queued_signal(slot)
        signal = instance_variable_get("@#{slot}_signal")
        return unless signal
        return if signal.fetch("expected_version") >= minimum_version_for(slot) &&
          signal_identity_matches?(slot, signal)

        instance_variable_set("@#{slot}_signal", nil)
        ignore_signal
      end

      def minimum_version_for(slot)
        if slot == :release && @build_signal
          @build_signal.fetch("expected_version")
        elsif slot == :build && @build_expected_version
          @build_expected_version
        else
          @input.fetch("expected_version")
        end
      end

      def ignore_signal
        @ignored_signal_count = [ @ignored_signal_count + 1, 1_000 ].min
        nil
      end

      def terminal_signal?
        @invalid_signal || @signal_conflict || @cancellation_signal
      end

      def terminal_result
        if @cancellation_signal
          @state = "canceling"
          cancellation = Temporalio::Workflow.execute_activity(
            Activities::RequestBuildCancellation,
            @cancellation_signal,
            activity_id: "build/cancel/#{@cancellation_signal.fetch("operation_id")}",
            schedule_to_close_timeout: 120,
            start_to_close_timeout: 30,
            retry_policy: Temporalio::RetryPolicy.new(
              initial_interval: 1,
              backoff_coefficient: 2.0,
              max_interval: 15,
              max_attempts: 5
            )
          )
          @expected_version = [ @expected_version, cancellation.fetch("current_version") ].max
          @state = "canceled"
          result("canceled_observed")
        else
          @state = "failed"
          result(
            "failed_observed",
            "failure_code" => @invalid_signal ? "invalid_signal" : "signal_conflict"
          )
        end
      end

      def result(status, details = {})
        {
          "contract_version" => 1,
          "deployment_id" => @input.fetch("deployment_id"),
          "status" => status,
          "expected_version" => @expected_version,
          "ignored_signal_count" => @ignored_signal_count
        }.merge(details)
      end
    end
  end
end
