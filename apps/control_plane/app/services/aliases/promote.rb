module Aliases
  class Promote
    class RevisionNotReady < StandardError; end

    Result = Data.define(:alias_record)

    def self.call(context:, revision:, alias_type:, name:)
      new(context:, revision:, alias_type:, name:).call
    end

    def initialize(context:, revision:, alias_type:, name:)
      @context = context
      @revision = revision
      @alias_type = alias_type.to_s
      @name = name.to_s
    end

    def call
      raise RevisionNotReady unless @revision.status == "ready"

      candidate = Alias.new(
        organization: @revision.organization,
        project: @revision.project,
        service: @revision.service,
        environment: @revision.environment,
        alias_type: @alias_type,
        name: @name,
        current_revision: @revision,
        current_revision_status: "ready"
      )
      authorize!(candidate)

      ApplicationRecord.transaction(requires_new: true) do
        lock_alias!
        alias_record = Alias.find_or_initialize_by(
          service: @revision.service,
          alias_type: @alias_type,
          name: @name
        )
        alias_record.lock! if alias_record.persisted?
        return Result.new(alias_record:) if alias_record.current_revision_id == @revision.id

        old_revision = alias_record.current_revision
        unless alias_record.persisted?
          alias_record.assign_attributes(
            organization: @revision.organization,
            project: @revision.project,
            service: @revision.service,
            environment: @revision.environment
          )
        end
        alias_record.assign_attributes(
          previous_revision: old_revision,
          previous_revision_status: old_revision ? "ready" : nil,
          current_revision: @revision,
          current_revision_status: "ready"
        )
        alias_record.save!
        promote_deployment!(@revision.deployment)
        supersede_deployment!(old_revision&.deployment)

        Result.new(alias_record:)
      end
    end

    private

    def authorize!(candidate)
      return if AliasPolicy.new(@context, candidate).promote?

      raise Pundit::NotAuthorizedError, "not allowed to promote this alias"
    end

    def lock_alias!
      key = "#{@revision.service_id}:#{@alias_type}:#{@name}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end

    def promote_deployment!(deployment)
      return if deployment.status == "promoted"

      Deployments::Transition.call(
        deployment:,
        to: :promoted,
        actor: @context.principal,
        cause: "alias_promoted",
        expected_lock_version: deployment.lock_version
      )
    end

    def supersede_deployment!(deployment)
      return unless deployment && deployment.status == "promoted"

      Deployments::Transition.call(
        deployment:,
        to: :superseded,
        actor: @context.principal,
        cause: "alias_superseded",
        expected_lock_version: deployment.lock_version
      )
    end
  end
end
