class DeploymentsController < OrganizationScopedController
  before_action :load_legacy_context
  before_action :load_deployment, only: %i[show live download_logs]

  def index
    authorize Deployment, :index?
    scope = policy_scope(Deployment)
      .includes(:project, :service, :environment, :revisions)
      .order(created_at: :desc, id: :desc)
    scope = scope.where(project: @project) if @project
    @branches = scope
      .where("deployments.source_snapshot ->> 'type' = 'git'")
      .reorder(nil)
      .distinct
      .pluck(Arel.sql("deployments.source_snapshot ->> 'reference'"))
      .compact
      .sort
    if params[:status].present?
      if Deployment::STATUSES.key?(params[:status])
        scope = scope.where(status: params[:status])
        @selected_status = params[:status]
      else
        @filter_error = "Choose a valid deployment status."
      end
    end
    if @project && params[:environment].present?
      environment = @project.environments.find_by(slug: params[:environment])
      environment ? scope = scope.where(environment:) : @filter_error = "Choose a valid environment."
    end
    if params[:branch].present?
      if @branches.include?(params[:branch])
        scope = scope.where("deployments.source_snapshot ->> 'reference' = ?", params[:branch])
      else
        @filter_error = "Choose a valid branch."
      end
    end
    if params[:date_from].present?
      scope = scope.where("deployments.created_at >= ?", Date.iso8601(params[:date_from]).beginning_of_day)
    end
    if params[:date_to].present?
      scope = scope.where("deployments.created_at <= ?", Date.iso8601(params[:date_to]).end_of_day)
    end
    @deployments = scope.limit(100)
  rescue Date::Error
    @filter_error = "Choose a valid date range."
    @deployments = scope.limit(100)
  end

  def show
    load_live_data
  end

  def live
    load_live_data
    return head :not_modified if request.headers["X-Lrail-Live-Version"] == @live_version

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "deployment-page-header",
            partial: "deployments/header"
          ),
          turbo_stream.replace(
            "deployment-failure",
            partial: "deployments/failure"
          ),
          turbo_stream.replace(
            "deployment_live",
            partial: "deployments/live"
          ),
          turbo_stream.replace(
            "deployment-history",
            partial: "deployments/history"
          )
        ]
      end
      format.html { render partial: "deployments/live", layout: false }
    end
  end

  def download_logs
    load_live_data
    content = @log_feed.entries.map do |entry|
      message = entry.message.gsub(/[\r\n]+/, " ")
      "[#{entry.timestamp.utc.iso8601(6)}] #{entry.stream.upcase} #{entry.level.upcase} #{message}"
    end.join("\n")
    response.set_header("Cache-Control", "no-store")
    send_data(
      "#{content}\n",
      filename: "deployment-#{@deployment.id}-logs.txt",
      type: "text/plain; charset=utf-8",
      disposition: "attachment"
    )
  end

  private

  def load_legacy_context
    @team = current_organization
    @project = if params[:project_name].present?
      current_organization.projects.find_by!(slug: params[:project_name])
    end
    @latest_teams = current_principal.organizations
      .where.not(id: current_organization.id)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
    @latest_projects = current_organization.projects
      .where(lifecycle_state: :active)
      .where.not(id: @project&.id)
      .order(updated_at: :desc, id: :desc)
      .limit(5)
    @latest_deployments = if @project
      policy_scope(Deployment)
        .where(project: @project)
        .where.not(id: params[:id])
        .includes(:project, :environment)
        .order(created_at: :desc, id: :desc)
        .limit(5)
    else
      []
    end
  end

  def load_deployment
    scope = policy_scope(Deployment)
      .includes(:project, :service, :environment, :configuration_snapshot)
    scope = scope.where(project: @project) if @project
    @deployment = scope.find(params[:id])
    @project ||= @deployment.project
    authorize @deployment, :show?
  end

  def load_live_data
    @transitions = @deployment.deployment_transitions.order(:sequence)
    actor_ids = @transitions.filter_map { |transition| transition.actor_id if transition.actor_type == "user" }
    @actors = User.joins(:memberships)
      .where(id: actor_ids, memberships: { organization_id: current_organization.id })
      .distinct
      .index_by(&:id)
    @builds = @deployment.builds.order(:attempt)
    @revision = @deployment.revisions.where(status: "ready").order(:created_at, :id).last
    @repository_connection = @deployment.service.repository_connection
    @alias_record = Alias.find_by(
      organization: current_organization,
      service: @deployment.service,
      environment: @deployment.environment,
      alias_type: :environment
    )
    @provider_logs = LocalProvider::LogClient.fetch(
      organization_id: @deployment.organization_id,
      deployment_id: @deployment.id
    )
    @log_feed = DeploymentLogs::Feed.call(
      deployment: @deployment,
      provider_result: @provider_logs,
      limit: 100,
      include_history: true
    )
    @failure_transition = @transitions.reverse.find { |transition| transition.error.present? }
    @can_manage = DeploymentPolicy.new(pundit_user, @deployment).transition?
    @serving = @alias_record&.current_revision&.deployment_id == @deployment.id
    @can_cancel = @can_manage && !@deployment.terminal? && @deployment.status != "canceling" && !@serving
    @can_promote = @can_manage && @deployment.status.in?(%w[ready superseded]) &&
      @revision&.status == "ready" && @alias_record&.current_revision_id != @revision.id
    previous_deployment = @alias_record&.previous_revision&.deployment
    @can_rollback = @can_manage && @serving && previous_deployment&.status.in?(
      Aliases::Promote::PROMOTABLE_DEPLOYMENT_STATUSES
    )
    @can_redeploy = @can_manage && @deployment.status.in?(%w[ready promoted superseded canceled failed])
    @live_version = Digest::SHA256.hexdigest(
      [
        @deployment.lock_version,
        @alias_record&.lock_version,
        @log_feed.next_cursor,
        @log_feed.provider_status,
        @log_feed.truncated,
        @provider_logs.retained
      ].join(":"))
  end
end
