module Api
  module V1
    class ProjectsController < BaseController
      def create
        mutation = Api::Idempotency::Execute.call(
          organization: current_organization,
          key: request.headers["Idempotency-Key"],
          operation: "createProject",
          payload: project_params.to_h.merge("organization_id" => current_organization.id)
        ) do
          result = Projects::Create.call(
            context: pundit_user,
            name: project_params.fetch(:name),
            slug: project_params[:slug]
          )

          {
            status: :created,
            body: serialize(result.project),
            resource: result.project
          }
        end

        response.set_header("Idempotency-Replayed", "true") if mutation.replayed

        render json: mutation.body, status: mutation.status
      end

      private

      def project_params
        params.permit(:organization_id, :name, :slug).slice(:name, :slug)
      end

      def serialize(project)
        {
          id: project.id,
          organization_id: project.organization_id,
          name: project.name,
          slug: project.slug,
          created_at: project.created_at.iso8601(6)
        }
      end
    end
  end
end
