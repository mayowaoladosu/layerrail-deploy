class ProjectsController < OrganizationScopedController
  before_action :load_project

  def show
    @team = current_organization
    @environments = @project.environments
      .where(lifecycle_state: :active)
      .order(kind: :asc, created_at: :asc, id: :asc)
    @deployments = policy_scope(Deployment)
      .where(project: @project)
      .includes(:project, :service, :environment)
      .order(created_at: :desc, id: :desc)
      .limit(10)
    @latest_teams = current_principal.organizations
      .where.not(id: @team.id)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
    @latest_projects = @team.projects
      .where(lifecycle_state: :active)
      .where.not(id: @project.id)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
  end

  private

  def load_project
    @project = current_organization.projects
      .where(lifecycle_state: :active)
      .find_by!(slug: params[:project_name])
  end
end
