module Deployments
  class Create
    class IdempotencyConflict < StandardError; end
    class InvalidSource < StandardError; end

    Result = Data.define(:deployment, :replayed)

    def self.call(context:, service:, environment:, source:, idempotency_key:, correlation_id:, trigger:)
      new(
        context:,
        service:,
        environment:,
        source:,
        idempotency_key:,
        correlation_id:,
        trigger:
      ).call
    end

    def initialize(context:, service:, environment:, source:, idempotency_key:, correlation_id:, trigger:)
      @context = context
      @service = service
      @environment = environment
      @source = normalize_source(source)
      @idempotency_key = idempotency_key.to_s
      @correlation_id = correlation_id.to_s
      @trigger = trigger
    end

    def call
      candidate = Deployment.new(
        organization: @context&.organization,
        project: @service.project,
        service: @service,
        environment: @environment,
        source_snapshot: @source,
        source_digest: source_digest,
        runtime_policy_snapshot: GitProviders::Types.deep_freeze(@service.runtime_policy),
        build_settings_snapshot: build_settings,
        idempotency_key: @idempotency_key,
        correlation_id: @correlation_id,
        trigger: @trigger,
        status: :created
      )
      authorize!(candidate)

      ApplicationRecord.transaction(requires_new: true) do
        lock_idempotency!
        existing = Deployment.find_by(organization: @context.organization, idempotency_key: @idempotency_key)
        return replay(existing) if existing

        configuration_snapshot = Configurations::Resolve.call(
          context: @context,
          project: @service.project,
          environment: @environment,
          service: @service
        ).snapshot
        candidate.configuration_snapshot = configuration_snapshot
        candidate.save!
        transition = candidate.deployment_transitions.create!(
          correlation_id: candidate.correlation_id,
          sequence: 1,
          from_status: nil,
          to_status: "created",
          actor_type: @context.system? ? "system" : "user",
          actor_id: @context.principal&.id,
          cause: @trigger.to_s,
          error: {},
          occurred_at: Time.current
        )
        Deployments::PublishTransition.call(deployment: candidate, transition:)
        publish_request!(candidate)

        Result.new(deployment: candidate, replayed: false)
      end
    end

    private

    def normalize_source(source)
      raise InvalidSource unless source.is_a?(Hash)

      normalized = source.to_h { |key, value| [ key.to_s, value.to_s.strip ] }.sort.to_h
      allowed = %w[type reference commit_sha repository_id digest]
      raise InvalidSource unless (normalized.keys - allowed).empty?
      raise InvalidSource unless normalized["type"].in?(%w[git oci])
      raise InvalidSource if normalized["reference"].blank?
      if normalized["type"] == "git"
        raise InvalidSource unless normalized["commit_sha"]&.match?(/\A[0-9a-f]{40,64}\z/)
        raise InvalidSource if normalized["repository_id"].blank?
      elsif normalized["digest"].blank?
        raise InvalidSource
      end

      GitProviders::Types.deep_freeze(normalized)
    end

    def source_digest
      @source_digest ||= Digest::SHA256.hexdigest(JSON.generate(@source))
    end

    def build_settings
      GitProviders::Types.deep_freeze(
        "workload_type" => @service.workload_type,
        "source_type" => @service.source_type
      )
    end

    def replay(existing)
      unless existing.service_id == @service.id &&
          existing.environment_id == @environment.id &&
          existing.source_digest == source_digest
        raise IdempotencyConflict
      end

      publish_request!(existing)

      Result.new(deployment: existing, replayed: true)
    end

    def publish_request!(deployment)
      OutboxEvents::Publish.call(
        organization: deployment.organization,
        resource_id: deployment.id,
        event_type: "deployment.requested.v1",
        correlation_id: deployment.correlation_id,
        idempotency_key: "deployment:#{deployment.id}:requested",
        producer: "control-plane",
        data: {
          "deployment_id" => deployment.id,
          "service_id" => deployment.service_id,
          "environment_id" => deployment.environment_id,
          "configuration_snapshot_id" => deployment.configuration_snapshot_id,
          "source_digest" => deployment.source_digest,
          "expected_version" => 0,
          "trigger" => deployment.trigger
        }
      )
    end

    def authorize!(candidate)
      return if DeploymentPolicy.new(@context, candidate).create?

      raise Pundit::NotAuthorizedError, "not allowed to create this deployment"
    end

    def lock_idempotency!
      key = "#{@context.organization.id}:#{@idempotency_key}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
  end
end
