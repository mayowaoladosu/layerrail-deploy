module BuildEvents
  class Consume
    class InvalidEvent < StandardError; end

    Result = Data.define(:result, :replayed)
    EVENT_TYPE = "deployment.build.completed.v1".freeze

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
        consumer: "build-controller-events",
        envelope: @envelope.to_h
      ) do
        process
      end

      Result.new(result: consumed.result, replayed: consumed.replayed)
    end

    private

    def validate_common!
      raise InvalidEvent unless @envelope.producer == "build-controller"
      raise InvalidEvent unless @envelope.event_type == EVENT_TYPE
      raise InvalidEvent unless @data.is_a?(Hash)
      raise InvalidEvent unless @data["contract_version"] == 1
      raise InvalidEvent unless @data["status"].in?(%w[completed failed])
      raise InvalidEvent unless @data["expected_version"].is_a?(Integer)
      %w[operation_id deployment_id build_id].each do |key|
        raise InvalidEvent unless Events::Envelope::UUID_PATTERN.match?(@data[key].to_s)
      end

      @build = Build.find_by(id: @data["build_id"])
      raise InvalidEvent unless @build
      @deployment = @build.deployment
      raise InvalidEvent unless @data["deployment_id"] == @deployment.id
      raise InvalidEvent unless @envelope.organization_id == @deployment.organization_id
      raise InvalidEvent unless @envelope.resource_id == @deployment.id
      raise InvalidEvent unless @envelope.correlation_id == @deployment.correlation_id

      request = OutboxEvent.find_by(
        id: @data["operation_id"],
        organization_id: @deployment.organization_id,
        resource_id: @deployment.id,
        event_type: "deployment.requested.v1"
      )
      raise InvalidEvent unless request

      @data["status"] == "completed" ? validate_completed! : validate_failed!
    end

    def validate_completed!
      required = %w[
        contract_version operation_id deployment_id build_id expected_version
        status revision_id artifact_digest evidence region cell
      ]
      raise InvalidEvent unless @data.keys.sort == required.sort
      raise InvalidEvent unless Events::Envelope::UUID_PATTERN.match?(@data["revision_id"].to_s)
      expected_revision_id = if @build.status == "succeeded"
        @build.revision&.id
      else
        @build.evidence["planned_revision_id"]
      end
      raise InvalidEvent unless @data["revision_id"] == expected_revision_id
      raise InvalidEvent unless @data["artifact_digest"]&.match?(/\Asha256:[0-9a-f]{64}\z/)
      raise InvalidEvent unless bounded_string?(@data["region"], 64)
      raise InvalidEvent unless bounded_string?(@data["cell"], 64)
      evidence = @data["evidence"]
      raise InvalidEvent unless evidence.is_a?(Hash) && evidence["scan_status"] == "passed"
      raise InvalidEvent unless evidence["plan_type"].in?(%w[dockerfile_web node_web plain_static node_static])
      raise InvalidEvent unless evidence["artifact_kind"].in?(%w[oci static])
      raise InvalidEvent if evidence.to_json.bytesize > 32.kilobytes
    end

    def validate_failed!
      required = %w[
        contract_version operation_id deployment_id build_id expected_version
        status failure_code error evidence
      ]
      raise InvalidEvent unless @data.keys.sort == required.sort
      raise InvalidEvent unless @data["failure_code"]&.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
      error = @data["error"]
      raise InvalidEvent unless error.is_a?(Hash) && error.keys.sort == %w[code message phase]
      raise InvalidEvent unless bounded_string?(error["phase"], 64)
      raise InvalidEvent unless bounded_string?(error["code"], 64)
      raise InvalidEvent unless bounded_string?(error["message"], 500)
      evidence = @data["evidence"]
      raise InvalidEvent unless evidence.is_a?(Hash)
      raise InvalidEvent if evidence.to_json.bytesize > 32.kilobytes
    end

    def bounded_string?(value, maximum)
      value.is_a?(String) && value.present? && value == value.strip && value.bytesize <= maximum
    end

    def process
      @deployment.lock!
      return ignored_result unless @deployment.lock_version == @data["expected_version"]

      if @data["status"] == "completed"
        completed_result
      else
        failed_result
      end
    end

    def completed_result
      result = Builds::Complete.call(
        build: @build,
        revision_id: @data.fetch("revision_id"),
        artifact_digest: @data.fetch("artifact_digest"),
        evidence: @data.fetch("evidence"),
        region: @data.fetch("region"),
        cell: @data.fetch("cell")
      )
      publish_signal(
        status: "completed",
        artifact_digest: result.build.artifact_digest
      )
      {
        "deployment_id" => @deployment.id,
        "build_id" => result.build.id,
        "revision_id" => result.revision.id,
        "ignored" => false
      }
    end

    def failed_result
      result = Builds::Fail.call(
        build: @build,
        retryable: false,
        error: @data.fetch("error"),
        evidence: @data.fetch("evidence")
      )
      publish_signal(
        status: "failed",
        failure_code: @data.fetch("failure_code")
      )
      {
        "deployment_id" => @deployment.id,
        "build_id" => result.build.id,
        "revision_id" => nil,
        "ignored" => false
      }
    end

    def publish_signal(status:, artifact_digest: nil, failure_code: nil)
      data = {
        "deployment_id" => @deployment.id,
        "operation_id" => @data.fetch("operation_id"),
        "expected_version" => @deployment.reload.lock_version,
        "build_id" => @build.id,
        "status" => status
      }
      data["artifact_digest"] = artifact_digest if artifact_digest
      data["failure_code"] = failure_code if failure_code
      OutboxEvents::Publish.call(
        organization: @deployment.organization,
        resource_id: @deployment.id,
        event_type: EVENT_TYPE,
        correlation_id: @deployment.correlation_id,
        idempotency_key: "build:#{@build.id}:workflow-result",
        producer: "build-controller",
        data:
      )
    end

    def ignored_result
      {
        "deployment_id" => @deployment.id,
        "build_id" => @build.id,
        "revision_id" => @build.revision&.id,
        "ignored" => true
      }
    end
  end
end
