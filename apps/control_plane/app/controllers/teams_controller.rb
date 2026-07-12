class TeamsController < OrganizationScopedController
  def show
    @team = current_organization
    @projects = @team.projects
      .where(lifecycle_state: :active)
      .includes(:services, :environments)
      .order(updated_at: :desc, id: :desc)
      .limit(8)
    @deployments = policy_scope(Deployment)
      .includes(:project, :service, :environment)
      .order(created_at: :desc, id: :desc)
      .limit(10)
    load_navigation
  end

  def projects
    @team = current_organization
    @projects = @team.projects
      .where(lifecycle_state: :active)
      .includes(:services)
      .order(name: :asc, id: :asc)
    load_navigation
  end

  private

  def load_navigation
    @latest_teams = current_principal.organizations
      .where.not(id: @team.id)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
    @latest_projects = @team.projects
      .where(lifecycle_state: :active)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
  end
end
