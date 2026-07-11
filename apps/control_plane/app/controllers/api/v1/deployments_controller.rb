module Api
  module V1
    class DeploymentsController < BaseController
      rescue_from Deployments::Create::InvalidSource, with: :render_invalid_source
      rescue_from Deployments::Transition::InvalidTransition, with: :render_invalid_transition
      rescue_from Deployments::Transition::StaleTransition, with: :render_stale_transition

      def create
        service = scoped_service
        return render_not_found unless service

        environment = deployment_environment(service)
        return render_not_found unless environment

        source = deployment_source
        return if performed?
        mutation = Api::Idempotency::Execute.call(
          organization: current_organization,
          key: request.headers["Idempotency-Key"],
          operation: "createDeployment",
          payload: {
            "service_id" => service.id,
            "environment_id" => environment.id,
            "source" => source
          }
        ) do
          result = Deployments::Create.call(
            context: pundit_user,
            service:,
            environment:,
            source:,
            idempotency_key: request.headers["Idempotency-Key"],
            correlation_id: @correlation_id,
            trigger: :manual
          )

          {
            status: :accepted,
            body: serialize_deployment(result.deployment),
            resource: result.deployment
          }
        end

        render_mutation(mutation)
      end

      def show
        deployment = scoped_deployment
        return render_not_found unless deployment

        authorize deployment, :show?
        render json: serialize_deployment(deployment), status: :ok
      end

      def cancel
        deployment = scoped_deployment
        return render_not_found unless deployment

        authorize deployment, :transition?
        reason = params[:reason]
        unless reason.nil? || (reason.is_a?(String) && reason.length <= 500)
          return render_validation_error(:reason, "must be a string with at most 500 characters")
        end

        mutation = Api::Idempotency::Execute.call(
          organization: current_organization,
          key: request.headers["Idempotency-Key"],
          operation: "cancelDeployment",
          payload: {
            "deployment_id" => deployment.id,
            "reason" => reason
          }
        ) do
          result = Deployments::Transition.call(
            deployment:,
            to: :canceling,
            actor: current_principal,
            cause: "cancellation_requested",
            expected_lock_version: deployment.lock_version
          )

          {
            status: :accepted,
            body: serialize_operation(result.event),
            resource: result.deployment
          }
        end

        render_mutation(mutation)
      end

      private

      def organization_id_from_request
        if params[:service_id]
          Service.joins(:project).where(id: params[:service_id]).pick("projects.organization_id")
        else
          Deployment.where(id: params[:deployment_id]).pick(:organization_id)
        end
      end

      def scoped_service
        Service.joins(:project).find_by(
          id: params[:service_id],
          projects: { organization_id: current_organization.id }
        )
      end

      def scoped_deployment
        Deployment.find_by(id: params[:deployment_id], organization_id: current_organization.id)
      end

      def deployment_environment(service)
        if params[:environment_id].present?
          service.project.environments.find_by(id: params[:environment_id])
        else
          service.project.environments.find_by(kind: :production)
        end
      end

      def deployment_source
        source = params.require(:source)
        allowed = %w[type reference repository_id commit_sha digest root_directory]
        if (source.keys - allowed).any?
          render_validation_error(:source, "contains unsupported fields")
          return
        end

        source.permit(*allowed).to_h
      end

      def render_invalid_source
        render_validation_error(:source, "is invalid")
      end

      def render_invalid_transition
        render_conflict("invalid_transition", "The deployment cannot make that transition")
      end

      def render_stale_transition
        render_conflict("stale_resource", "The deployment changed before the operation completed")
      end
    end
  end
end
