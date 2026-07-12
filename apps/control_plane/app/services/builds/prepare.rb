module Builds
  class Prepare
    class InvalidDeployment < StandardError; end
    class StaleDeployment < StandardError; end

    Result = Data.define(
      :build,
      :deployment,
      :revision_id,
      :command,
      :current_version,
      :deployment_status,
      :replayed
    )

    def self.call(deployment:, operation_id:, expected_lock_version:)
      new(
        deployment:,
        operation_id:,
        expected_lock_version:
      ).call
    end

    def initialize(deployment:, operation_id:, expected_lock_version:)
      @deployment = deployment
      @operation_id = operation_id.to_s
      @expected_lock_version = expected_lock_version
      @idempotency_key = "orchestrator:#{@operation_id}:build"
    end

    def call
      validate_request!

      ApplicationRecord.transaction(requires_new: true) do
        @deployment.lock!
        build = @deployment.builds.find_by(idempotency_key: @idempotency_key)
        replayed = build.present?
        unless build
          raise StaleDeployment unless @deployment.lock_version == @expected_lock_version
          raise InvalidDeployment unless @deployment.status == "created"

          @deployment = transition(@deployment, :queued, "workflow_queued")
          @deployment = transition(@deployment, :preparing, "workflow_preparing")
          build = Builds::Start.call(
            deployment: @deployment,
            idempotency_key: @idempotency_key,
            expected_lock_version: @deployment.lock_version
          ).build
          build.update!(evidence: { "planned_revision_id" => SecureRandom.uuid_v7 })
        end

        command = existing_command(build)
        unless command
          revision_id = build.evidence.fetch("planned_revision_id")
          command = publish_command(build:, revision_id:)
        end
        validate_existing!(build, command)
        revision_id = command.data.fetch("revision_id")

        Result.new(
          build:,
          deployment: build.deployment,
          revision_id:,
          command:,
          current_version: command.data.fetch("expected_version"),
          deployment_status: "building",
          replayed:
        )
      end
    end

    private

    def validate_request!
      raise InvalidDeployment unless Events::Envelope::UUID_PATTERN.match?(@operation_id)
      raise InvalidDeployment unless @expected_lock_version.is_a?(Integer)
      raise InvalidDeployment unless @deployment.source_snapshot["type"] == "git"
      raise InvalidDeployment unless @deployment.build_settings_snapshot["workload_type"].in?(%w[web static])

      source = @deployment.source_snapshot
      raise InvalidDeployment unless source["commit_sha"]&.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
      connection = @deployment.service.repository_connection
      raise InvalidDeployment unless connection&.status_active?
      raise InvalidDeployment unless connection.organization_id == @deployment.organization_id
      raise InvalidDeployment unless connection.provider_repository_id == source["repository_id"]

      request_event = OutboxEvent.find_by(
        id: @operation_id,
        organization_id: @deployment.organization_id,
        resource_id: @deployment.id,
        event_type: "deployment.requested.v1"
      )
      raise InvalidDeployment unless request_event
      raise InvalidDeployment unless request_event.data["expected_version"] == @expected_lock_version
    end

    def existing_command(build)
      OutboxEvent.find_by(
        organization_id: build.organization_id,
        resource_id: build.id,
        event_type: "build.requested.v1",
        idempotency_key: "build:#{build.id}:requested"
      )
    end

    def validate_existing!(build, command)
      raise InvalidDeployment unless build.deployment_id == @deployment.id
      raise InvalidDeployment unless build.status.in?(%w[running succeeded failed canceled])
      raise InvalidDeployment unless command.data["operation_id"] == @operation_id
      raise InvalidDeployment unless command.data["build_id"] == build.id
      raise InvalidDeployment unless command.data["deployment_id"] == @deployment.id
      raise InvalidDeployment unless command.data["expected_version"].is_a?(Integer)
      revision_id = command.data["revision_id"]
      raise InvalidDeployment unless Events::Envelope::UUID_PATTERN.match?(revision_id.to_s)
      planned_revision_id = build.evidence["planned_revision_id"]
      raise InvalidDeployment if planned_revision_id && planned_revision_id != revision_id
      raise InvalidDeployment if build.revision && build.revision.id != revision_id
    end

    def transition(deployment, status, cause)
      Deployments::Transition.call(
        deployment:,
        to: status,
        actor: nil,
        cause:,
        expected_lock_version: deployment.lock_version
      ).deployment
    end

    def publish_command(build:, revision_id:)
      deployment = build.deployment
      source = deployment.source_snapshot
      OutboxEvents::Publish.call(
        organization: deployment.organization,
        resource_id: build.id,
        event_type: "build.requested.v1",
        correlation_id: deployment.correlation_id,
        idempotency_key: "build:#{build.id}:requested",
        producer: "control-plane",
        data: {
          "contract_version" => 1,
          "command_type" => "build.start",
          "operation_id" => @operation_id,
          "organization_id" => deployment.organization_id,
          "deployment_id" => deployment.id,
          "build_id" => build.id,
          "revision_id" => revision_id,
          "service_id" => deployment.service_id,
          "expected_version" => deployment.lock_version,
          "workload_type" => deployment.build_settings_snapshot.fetch("workload_type"),
          "repository" => "lrail/#{deployment.organization_id}/#{deployment.service_id}",
          "source_commit" => source.fetch("commit_sha"),
          "source_root" => source["root_directory"].presence || ".",
          "descriptor_digest" => "sha256:#{deployment.source_digest}"
        }
      ).event
    end
  end
end
