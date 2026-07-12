module LocalProviderEvents
  class Consume
    class InvalidEvent < StandardError; end

    Result = Data.define(:result, :replayed)
    EVENT_TYPES = %w[
      deployment.runtime.ready.v1
      deployment.runtime.failed.v1
      deployment.runtime.canceled.v1
    ].freeze

    def self.call(envelope:)
      new(envelope:).call
    end

    def initialize(envelope:)
      @envelope = Events::Envelope.parse(envelope)
      @data = @envelope.data
      validate_common!
    rescue Events::Envelope::Invalid
      raise InvalidEvent
    end

    def call
      consumed = EventConsumers::Process.call(
        consumer: "local-provider",
        envelope: @envelope.to_h
      ) do
        process
      end

      Result.new(result: consumed.result, replayed: consumed.replayed)
    end

    private

    def validate_common!
      raise InvalidEvent unless @envelope.producer == "local-provider"
      raise InvalidEvent unless @envelope.event_type.in?(EVENT_TYPES)

      @deployment = Deployment.find_by(id: @data["deployment_id"])
      raise InvalidEvent unless @deployment
      raise InvalidEvent unless @envelope.organization_id == @deployment.organization_id
      raise InvalidEvent unless @envelope.resource_id == @deployment.id
      raise InvalidEvent unless @envelope.correlation_id == @deployment.correlation_id
      raise InvalidEvent unless @data["expected_version"].is_a?(Integer)

      command_type = if @envelope.event_type == "deployment.runtime.canceled.v1"
        "deployment.cancellation.requested.v1"
      else
        "deployment.requested.v1"
      end
      @command = OutboxEvent.find_by(
        id: @data["operation_id"],
        organization_id: @deployment.organization_id,
        resource_id: @deployment.id,
        event_type: command_type
      )
      raise InvalidEvent unless @command
      raise InvalidEvent unless @command.data["expected_version"] == @data["expected_version"]

      if @envelope.event_type == "deployment.runtime.ready.v1"
        validate_ready!
      elsif @envelope.event_type == "deployment.runtime.failed.v1"
        validate_failure!
      end
    end

    def validate_ready!
      raise InvalidEvent unless @deployment.source_snapshot["type"] == "oci"
      raise InvalidEvent unless @data["artifact_digest"] == @deployment.source_snapshot["digest"]
      raise InvalidEvent unless @data["artifact_digest"]&.match?(/\Asha256:[0-9a-f]{64}\z/)
      raise InvalidEvent unless bounded_string?(@data["region"], 64)
      raise InvalidEvent unless bounded_string?(@data["cell"], 64)
      readiness = @data["readiness"]
      raise InvalidEvent unless readiness.is_a?(Hash) && readiness["status"] == "passed"
      raise InvalidEvent if readiness.to_json.bytesize > 16.kilobytes
    end

    def validate_failure!
      raise InvalidEvent unless bounded_string?(@data["phase"], 120)
      raise InvalidEvent unless bounded_string?(@data["code"], 120)
      raise InvalidEvent unless bounded_string?(@data["message"], 500)
      diagnostic = @data["diagnostic_reference"]
      raise InvalidEvent unless diagnostic.nil? || bounded_string?(diagnostic, 255)
    end

    def bounded_string?(value, maximum)
      value.is_a?(String) && value.present? && value == value.strip && value.bytesize <= maximum
    end

    def process
      @deployment.lock!
      return ignored_result unless @deployment.lock_version == @data.fetch("expected_version")

      if @envelope.event_type == "deployment.runtime.ready.v1"
        mark_ready
      elsif @envelope.event_type == "deployment.runtime.canceled.v1"
        mark_canceled
      else
        mark_failed
      end
    end

    def mark_ready
      deployment = transition(@deployment, :queued, "provider_queued")
      deployment = transition(deployment, :preparing, "provider_preparing")
      build = Builds::Start.call(
        deployment:,
        idempotency_key: "provider:#{@command.id}:artifact",
        expected_lock_version: deployment.lock_version
      ).build
      revision = Builds::Complete.call(
        build:,
        artifact_digest: @data.fetch("artifact_digest"),
        evidence: {
          "scan_status" => "passed",
          "source_type" => "trusted_oci",
          "provider_operation_id" => @command.id
        },
        region: @data.fetch("region"),
        cell: @data.fetch("cell")
      ).revision
      revision = Revisions::MarkReady.call(
        revision:,
        readiness: @data.fetch("readiness").merge("provider_operation_id" => @command.id)
      ).revision

      {
        "deployment_id" => @deployment.id,
        "revision_id" => revision.id,
        "ignored" => false
      }
    end

    def mark_failed
      error = {
        "phase" => @data.fetch("phase"),
        "code" => @data.fetch("code"),
        "message" => @data.fetch("message")
      }
      error["diagnostic_reference"] = @data["diagnostic_reference"] if @data["diagnostic_reference"]
      transition(@deployment, :failed, "provider_failed", error:)

      {
        "deployment_id" => @deployment.id,
        "revision_id" => nil,
        "ignored" => false
      }
    end

    def mark_canceled
      build = @deployment.builds.order(:attempt).last
      if build&.status == "running"
        Builds::Cancel.call(build:)
      else
        transition(@deployment, :canceled, "provider_canceled")
      end

      {
        "deployment_id" => @deployment.id,
        "revision_id" => nil,
        "ignored" => false
      }
    end

    def transition(deployment, status, cause, error: {})
      Deployments::Transition.call(
        deployment:,
        to: status,
        actor: nil,
        cause:,
        expected_lock_version: deployment.lock_version,
        error:
      ).deployment
    end

    def ignored_result
      {
        "deployment_id" => @deployment.id,
        "revision_id" => @deployment.revisions.order(:created_at, :id).last&.id,
        "ignored" => true
      }
    end
  end
end
