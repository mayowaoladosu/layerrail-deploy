# frozen_string_literal: true

require "logger"
require "temporalio/client"
require "temporalio/error"

module LrailOrchestrator
  class Bridge
    def initialize(temporal:, control_plane:, task_queue:, poll_interval:, logger: Logger.new($stdout))
      @temporal = temporal
      @control_plane = control_plane
      @task_queue = task_queue
      @poll_interval = poll_interval
      @logger = logger
      @stopping = false
    end

    def run
      until @stopping
        begin
          processed = run_once
          sleep(@poll_interval) unless processed
        rescue ControlPlaneClient::Unavailable, Temporalio::Error::RPCError
          @logger.warn("orchestrator dependency unavailable")
          sleep(@poll_interval)
        rescue ControlPlaneClient::Rejected
          @logger.error("orchestrator bridge request rejected")
          sleep(@poll_interval)
        end
      end
    end

    def stop
      @stopping = true
    end

    def run_once
      command = @control_plane.claim
      return false unless command

      begin
        dispatch(command.event)
        @control_plane.finalize(
          event_id: command.event.fetch("event_id"),
          claim_token: command.claim_token,
          outcome: "published"
        )
      rescue Contracts::Invalid
        @control_plane.finalize(
          event_id: command.event.fetch("event_id"),
          claim_token: command.claim_token,
          outcome: "rejected",
          safe_error: "workflow_contract_invalid"
        )
      rescue Temporalio::Error
        @control_plane.finalize(
          event_id: command.event.fetch("event_id"),
          claim_token: command.claim_token,
          outcome: "retry",
          safe_error: "temporal_operation_unknown"
        )
      end
      true
    end

    private

    def dispatch(envelope)
      case envelope.fetch("event_type")
      when "deployment.requested.v1"
        start_workflow(envelope)
      when "deployment.cancellation.requested.v1"
        signal(envelope, Workflows::DeploymentWorkflow.cancellation_requested, Contracts.method(:cancellation_signal))
      when "deployment.build.completed.v1"
        signal(envelope, Workflows::DeploymentWorkflow.build_completed, Contracts.method(:build_signal))
      when "deployment.runtime.ready.v1", "deployment.runtime.failed.v1", "deployment.runtime.canceled.v1"
        signal(envelope, Workflows::DeploymentWorkflow.release_reconciled, Contracts.method(:release_signal))
      else
        raise Contracts::Invalid, "unsupported workflow event"
      end
    end

    def start_workflow(envelope)
      input = Contracts.deployment_input(envelope)
      @temporal.start_workflow(
        Workflows::DeploymentWorkflow,
        input,
        id: workflow_id(input.fetch("deployment_id")),
        task_queue: @task_queue,
        execution_timeout: 30 * 24 * 60 * 60,
        id_reuse_policy: Temporalio::WorkflowIDReusePolicy::REJECT_DUPLICATE,
        id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::USE_EXISTING
      )
    rescue Temporalio::Error::WorkflowAlreadyStartedError
      nil
    end

    def signal(envelope, definition, parser)
      value = parser.call(envelope)
      handle = @temporal.workflow_handle(workflow_id(value.fetch("deployment_id")))
      handle.signal(definition, value)
    rescue Temporalio::Error::RPCError
      raise unless closed_workflow?(handle)
    end

    def closed_workflow?(handle)
      description = handle&.describe
      description && description.status != Temporalio::Client::WorkflowExecutionStatus::RUNNING
    rescue Temporalio::Error
      false
    end

    def workflow_id(deployment_id)
      "deployment/#{deployment_id}"
    end
  end
end
