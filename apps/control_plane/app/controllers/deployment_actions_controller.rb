class DeploymentActionsController < OrganizationScopedController
  before_action :load_deployment

  def cancel
    Deployments::Cancel.call(
      context: pundit_user,
      deployment: @deployment,
      expected_lock_version: @deployment.lock_version
    )
    redirect_to deployment_path, notice: "Cancellation requested. The runtime will stop without changing a serving URL.", status: :see_other
  rescue Deployments::Cancel::InUse
    redirect_with_alert("This deployment is serving traffic. Promote or roll back to another revision before canceling it.")
  rescue Deployments::Transition::InvalidTransition, Deployments::Transition::StaleTransition
    redirect_with_alert("The deployment changed before cancellation completed. Review its current status and try again if it is still eligible.")
  end

  def redeploy
    unless @deployment.status.in?(%w[ready promoted superseded canceled failed])
      return redirect_with_alert("This deployment is still changing. Wait for a stable outcome before redeploying it.")
    end

    operation_id = params[:operation_id].to_s
    unless Events::Envelope::UUID_PATTERN.match?(operation_id)
      return redirect_with_alert("The redeploy request expired. Refresh the page and try again.")
    end

    result = Deployments::Create.call(
      context: pundit_user,
      service: @deployment.service,
      environment: @deployment.environment,
      source: @deployment.source_snapshot,
      idempotency_key: "web:redeploy:#{operation_id}",
      correlation_id: SecureRandom.uuid_v7,
      trigger: :redeploy
    )
    redirect_to deployment_path(result.deployment),
      notice: "Redeploy accepted. Progress is saved and will continue if this page is closed.",
      status: :see_other
  rescue Deployments::Create::IdempotencyConflict
    redirect_with_alert("That redeploy request was already used for different inputs. Refresh the page and try again.")
  end

  def promote
    unless @deployment.status.in?(%w[ready superseded])
      return redirect_with_alert("Only an active ready or superseded deployment can be promoted.")
    end

    revision = @deployment.revisions.where(status: "ready").order(:created_at, :id).last
    unless revision
      return redirect_with_alert("This deployment has no ready revision to promote. Wait for readiness or inspect the failure details.")
    end

    Aliases::Promote.call(
      context: pundit_user,
      revision:,
      alias_type: :environment,
      name: @deployment.environment.slug
    )
    redirect_to deployment_path,
      notice: "Promotion requested. The environment URL is moving to this ready revision.",
      status: :see_other
  rescue Aliases::Promote::RevisionNotReady
    redirect_with_alert("The revision is no longer ready. Refresh the page before promoting it.")
  rescue Deployments::Transition::InvalidTransition, Deployments::Transition::StaleTransition
    redirect_with_alert("The deployment changed before promotion completed. Refresh the page to review its current status.")
  end

  def rollback
    alias_record = Alias.find_by!(
      organization: current_organization,
      service: @deployment.service,
      environment: @deployment.environment,
      alias_type: :environment
    )
    previous = alias_record.previous_revision
    unless alias_record.current_revision.deployment_id == @deployment.id
      return redirect_with_alert("This deployment is not serving the environment URL. Open the current deployment before rolling back.")
    end
    unless previous && previous.id == params[:revision_id]
      return redirect_with_alert("The previous revision changed. Refresh the page before rolling back.")
    end

    Aliases::Rollback.call(
      context: pundit_user,
      alias_record:,
      revision: previous,
      expected_lock_version: Integer(params[:expected_lock_version].to_s, 10)
    )
    redirect_to deployment_path,
      notice: "Rollback requested. The environment URL is returning to the previous healthy revision without rebuilding.",
      status: :see_other
  rescue ActiveRecord::RecordNotFound, ArgumentError, Aliases::Rollback::PreviousRevisionMissing,
    Aliases::Rollback::RevisionMismatch, Aliases::Rollback::StaleAlias
    redirect_with_alert("The routing state changed before rollback completed. Refresh the page to review the current and previous revisions.")
  end

  private

  def load_deployment
    scope = policy_scope(Deployment)
    if params[:project_name].present?
      project = current_organization.projects.find_by!(slug: params[:project_name])
      scope = scope.where(project:)
    end
    @deployment = scope.find(params[:id])
    authorize @deployment, :transition?
  end

  def deployment_path(deployment = @deployment)
    if params[:team_slug].present?
      project_deployment_path(current_organization.slug, deployment.project.slug, deployment)
    else
      organization_deployment_path(current_organization, deployment)
    end
  end

  def redirect_with_alert(message)
    redirect_to deployment_path, alert: message, status: :see_other
  end
end
