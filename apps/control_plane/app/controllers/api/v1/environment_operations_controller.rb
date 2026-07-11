module Api
  module V1
    class EnvironmentOperationsController < BaseController
      rescue_from Aliases::Promote::RevisionNotReady, with: :render_revision_not_ready
      rescue_from Aliases::Rollback::PreviousRevisionMissing, with: :render_previous_revision_missing
      rescue_from Aliases::Rollback::RevisionMismatch, with: :render_revision_mismatch
      rescue_from Aliases::Rollback::StaleAlias, with: :render_stale_alias

      def promote
        environment = scoped_environment
        return render_not_found unless environment
        authorize_alias_operation!

        revision = selected_revision(environment)
        return if performed?
        return render_not_found unless revision

        mutation = Api::Idempotency::Execute.call(
          organization: current_organization,
          key: request.headers["Idempotency-Key"],
          operation: "promoteEnvironment",
          payload: {
            "environment_id" => environment.id,
            "revision_id" => revision.id
          }
        ) do
          result = Aliases::Promote.call(
            context: pundit_user,
            revision:,
            alias_type: :environment,
            name: environment.slug
          )

          {
            status: :accepted,
            body: serialize_operation(result.event),
            resource: result.alias_record
          }
        end

        render_mutation(mutation)
      end

      def rollback
        environment = scoped_environment
        return render_not_found unless environment
        authorize_alias_operation!

        revision = selected_revision(environment)
        return if performed?
        return render_not_found unless revision

        alias_record = Alias.find_by(
          organization: current_organization,
          service: revision.service,
          environment:,
          alias_type: :environment,
          name: environment.slug
        )
        return render_not_found unless alias_record

        authorize alias_record, :promote?
        mutation = Api::Idempotency::Execute.call(
          organization: current_organization,
          key: request.headers["Idempotency-Key"],
          operation: "rollbackEnvironment",
          payload: {
            "environment_id" => environment.id,
            "revision_id" => revision.id
          }
        ) do
          result = Aliases::Rollback.call(
            context: pundit_user,
            alias_record:,
            revision:,
            expected_lock_version: alias_record.lock_version
          )

          {
            status: :accepted,
            body: serialize_operation(result.event),
            resource: result.alias_record
          }
        end

        render_mutation(mutation)
      end

      private

      def organization_id_from_request
        Environment.joins(:project)
          .where(id: params[:environment_id])
          .pick("projects.organization_id")
      end

      def scoped_environment
        Environment.joins(:project).find_by(
          id: params[:environment_id],
          projects: { organization_id: current_organization.id }
        )
      end

      def authorize_alias_operation!
        authorize Alias.new(organization: current_organization), :promote?
      end

      def selected_revision(environment)
        if params[:revision_id].blank?
          render_validation_error(:revision_id, "is required")
          return
        end

        Revision.find_by(
          id: params[:revision_id],
          organization_id: current_organization.id,
          environment_id: environment.id
        )
      end

      def render_revision_not_ready
        render_conflict("revision_not_ready", "Only a ready Revision can receive traffic")
      end

      def render_previous_revision_missing
        render_conflict("previous_revision_missing", "The Alias has no previous Revision")
      end

      def render_revision_mismatch
        render_conflict("revision_mismatch", "The selected Revision is not the previous Revision")
      end

      def render_stale_alias
        render_conflict("stale_resource", "The Alias changed before the operation completed")
      end
    end
  end
end
