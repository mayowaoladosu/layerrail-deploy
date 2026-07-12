class OrganizationScopedController < ApplicationController
  before_action :require_web_session!
  before_action :select_organization!

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

  private

  def select_organization!
    return if performed?

    @current_organization = current_principal.organizations.find_by(id: params[:organization_id])
    render_not_found unless @current_organization
  end

  def render_not_found
    render "errors/not_found", status: :not_found
  end

  def render_forbidden
    render "errors/forbidden", status: :forbidden
  end
end
