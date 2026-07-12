# frozen_string_literal: true

require "json"

module LrailOrchestrator
  module Contracts
    class Invalid < StandardError; end

    MAX_BYTES = 64 * 1024
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    WORKLOAD_TYPES = %w[web static].freeze
    BUILD_STATUSES = %w[completed failed].freeze
    RELEASE_STATUSES = %w[ready failed canceled].freeze
    DEPLOYMENT_STATUSES = %w[
      created queued preparing building scanning deploying verifying ready
      failed canceling canceled
    ].freeze

    module_function

    def deployment_input(envelope)
      envelope = object(envelope)
      exact_keys!(
        envelope,
        %w[event_id event_type occurred_at organization_id resource_id correlation_id idempotency_key producer schema_version data]
      )
      invalid! unless envelope["event_type"] == "deployment.requested.v1"
      invalid! unless envelope["producer"] == "control-plane"
      invalid! unless envelope["schema_version"] == 1
      data = object(envelope["data"])
      required = %w[
        deployment_id service_id environment_id configuration_snapshot_id
        source_digest workload_type expected_version
      ]
      invalid! unless required.all? { |key| data.key?(key) }
      deployment_id = uuid(data["deployment_id"])
      invalid! unless deployment_id == uuid(envelope["resource_id"])
      value = {
        "contract_version" => 1,
        "event_id" => uuid(envelope["event_id"]),
        "organization_id" => uuid(envelope["organization_id"]),
        "deployment_id" => deployment_id,
        "service_id" => uuid(data["service_id"]),
        "environment_id" => uuid(data["environment_id"]),
        "configuration_snapshot_id" => uuid(data["configuration_snapshot_id"]),
        "source_digest" => digest(data["source_digest"]),
        "workload_type" => enum(data["workload_type"], WORKLOAD_TYPES),
        "expected_version" => version(data["expected_version"]),
        "operation_id" => uuid(envelope["event_id"])
      }
      bounded(value)
    end

    def cancellation_signal(envelope)
      signal(
        envelope,
        event_type: "deployment.cancellation.requested.v1",
        producer: "control-plane"
      ) do |data|
        {
          "message_type" => "deployment.cancel",
          "transition_id" => uuid(data.fetch("transition_id"))
        }
      end
    end

    def build_signal(envelope)
      signal(
        envelope,
        event_type: "deployment.build.completed.v1",
        producer: "build-controller"
      ) do |data|
        status = enum(data.fetch("status"), BUILD_STATUSES)
        value = {
          "message_type" => status == "completed" ? "build.completed" : "build.failed",
          "build_id" => uuid(data.fetch("build_id")),
          "status" => status
        }
        if status == "completed"
          value["artifact_digest"] = digest(data.fetch("artifact_digest"))
        else
          value["failure_code"] = code(data.fetch("failure_code"))
        end
        value
      end
    end

    def release_signal(envelope)
      envelope = object(envelope)
      type = envelope["event_type"]
      invalid! unless %w[
        deployment.runtime.ready.v1
        deployment.runtime.failed.v1
        deployment.runtime.canceled.v1
      ].include?(type)
      signal(envelope, event_type: type, producer: "runtime-controller") do |data|
        status = {
          "deployment.runtime.ready.v1" => "ready",
          "deployment.runtime.failed.v1" => "failed",
          "deployment.runtime.canceled.v1" => "canceled"
        }.fetch(type)
        value = {
          "message_type" => "release.#{status}",
          "status" => status
        }
        value["revision_id"] = uuid(data.fetch("revision_id")) if status == "ready"
        value["artifact_digest"] = digest(data.fetch("artifact_digest")) if status == "ready"
        value["failure_code"] = code(data.fetch("code")) if status == "failed"
        value
      end
    end

    def workflow_operation(input)
      input = deployment_workflow_input(input)
      bounded(
        "contract_version" => 1,
        "operation_id" => input.fetch("operation_id"),
        "organization_id" => input.fetch("organization_id"),
        "deployment_id" => input.fetch("deployment_id"),
        "expected_version" => input.fetch("expected_version"),
        "stage" => "workflow_accepted"
      )
    end

    def workflow_operation_message(value)
      value = object(value)
      exact_keys!(value, %w[
        contract_version operation_id organization_id deployment_id
        expected_version stage
      ])
      invalid! unless value["contract_version"] == 1
      uuid(value["operation_id"])
      uuid(value["organization_id"])
      uuid(value["deployment_id"])
      version(value["expected_version"])
      invalid! unless value["stage"] == "workflow_accepted"
      bounded(value)
    end

    def operation_result(value)
      value = object(value)
      exact_keys!(value, %w[
        operation_id accepted stale current_version deployment_status
      ])
      uuid(value["operation_id"])
      invalid! unless [true, false].include?(value["accepted"])
      invalid! unless [true, false].include?(value["stale"])
      invalid! unless value["accepted"] != value["stale"]
      version(value["current_version"])
      enum(value["deployment_status"], DEPLOYMENT_STATUSES)
      bounded(value)
    end

    def build_prepared(value)
      value = object(value)
      exact_keys!(value, %w[
        contract_version operation_id organization_id deployment_id accepted
        stale current_version deployment_status build_id revision_id
      ])
      invalid! unless value["contract_version"] == 1
      %w[operation_id organization_id deployment_id build_id revision_id].each do |key|
        uuid(value[key])
      end
      invalid! unless value["accepted"] == true && value["stale"] == false
      version(value["current_version"])
      invalid! unless value["deployment_status"] == "building"
      bounded(value)
    end

    def build_workflow_signal(value)
      value = object(value)
      status = value["status"]
      required = signal_keys + %w[message_type build_id status]
      required += status == "completed" ? %w[artifact_digest] : %w[failure_code]
      exact_keys!(value, required)
      validate_signal_base(value)
      enum(status, BUILD_STATUSES)
      invalid! unless value["message_type"] == "build.#{status}"
      uuid(value["build_id"])
      status == "completed" ? digest(value["artifact_digest"]) : code(value["failure_code"])
      bounded(value)
    end

    def release_workflow_signal(value)
      value = object(value)
      status = value["status"]
      required = signal_keys + %w[message_type status]
      required += status == "ready" ? %w[revision_id artifact_digest] : []
      required += status == "failed" ? %w[failure_code] : []
      exact_keys!(value, required)
      validate_signal_base(value)
      enum(status, RELEASE_STATUSES)
      invalid! unless value["message_type"] == "release.#{status}"
      if status == "ready"
        uuid(value["revision_id"])
        digest(value["artifact_digest"])
      elsif status == "failed"
        code(value["failure_code"])
      end
      bounded(value)
    end

    def cancellation_workflow_signal(value)
      value = object(value)
      exact_keys!(value, signal_keys + %w[message_type transition_id])
      validate_signal_base(value)
      invalid! unless value["message_type"] == "deployment.cancel"
      uuid(value["transition_id"])
      bounded(value)
    end

    def deployment_workflow_input(value)
      value = object(value)
      exact_keys!(value, %w[
        contract_version event_id organization_id deployment_id service_id
        environment_id configuration_snapshot_id source_digest workload_type
        expected_version operation_id
      ])
      invalid! unless value["contract_version"] == 1
      %w[event_id organization_id deployment_id service_id environment_id configuration_snapshot_id operation_id].each do |key|
        uuid(value[key])
      end
      digest(value["source_digest"])
      enum(value["workload_type"], WORKLOAD_TYPES)
      version(value["expected_version"])
      bounded(value)
    end

    def signal(envelope, event_type:, producer:)
      envelope = object(envelope)
      invalid! unless envelope["event_type"] == event_type
      invalid! unless envelope["producer"] == producer
      invalid! unless envelope["schema_version"] == 1
      data = object(envelope["data"])
      deployment_id = uuid(data.fetch("deployment_id"))
      invalid! unless deployment_id == uuid(envelope["resource_id"])
      base = {
        "contract_version" => 1,
        "event_id" => uuid(envelope["event_id"]),
        "operation_id" => uuid(data.fetch("operation_id", envelope["event_id"])),
        "organization_id" => uuid(envelope["organization_id"]),
        "deployment_id" => deployment_id,
        "expected_version" => version(data.fetch("expected_version"))
      }
      bounded(base.merge(yield(data)))
    rescue KeyError
      invalid!
    end
    private_class_method :signal

    def signal_keys
      %w[
        contract_version event_id operation_id organization_id deployment_id
        expected_version
      ]
    end
    private_class_method :signal_keys

    def validate_signal_base(value)
      invalid! unless value["contract_version"] == 1
      %w[event_id operation_id organization_id deployment_id].each do |key|
        uuid(value[key])
      end
      version(value["expected_version"])
    end
    private_class_method :validate_signal_base

    def exact_keys!(value, keys)
      invalid! unless value.keys.sort == keys.sort
    end
    private_class_method :exact_keys!

    def object(value)
      invalid! unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }

      value
    end
    private_class_method :object

    def uuid(value)
      value = value.to_s
      invalid! unless UUID.match?(value)

      value
    end
    private_class_method :uuid

    def digest(value)
      value = value.to_s
      value = "sha256:#{value}" if value.match?(/\A[0-9a-f]{64}\z/)
      invalid! unless DIGEST.match?(value)

      value
    end
    private_class_method :digest

    def enum(value, allowed)
      value = value.to_s
      invalid! unless allowed.include?(value)

      value
    end
    private_class_method :enum

    def code(value)
      value = value.to_s
      invalid! unless value.match?(/\A[a-z][a-z0-9_]{0,63}\z/)

      value
    end
    private_class_method :code

    def version(value)
      invalid! unless value.is_a?(Integer) && value.between?(0, 2_147_483_647)

      value
    end
    private_class_method :version

    def bounded(value)
      invalid! if JSON.generate(value).bytesize > MAX_BYTES

      deep_copy(value)
    end
    private_class_method :bounded

    def deep_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [key.dup.freeze, deep_copy(child)] }.freeze
      when Array
        value.map { |child| deep_copy(child) }.freeze
      when String
        value.dup.freeze
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        invalid!
      end
    end
    private_class_method :deep_copy

    def invalid!
      raise Invalid, "workflow contract is invalid"
    end
    private_class_method :invalid!
  end
end
