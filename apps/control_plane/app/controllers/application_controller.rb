class ApplicationController < ActionController::Base
  include Pundit::Authorization
  helper_method :current_principal, :current_organization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def pundit_user
    AuthorizationContext.build(
      principal: current_principal,
      organization: current_organization
    )
  end

  def current_principal
    principal = request.env["lrail.authenticated_principal"]
    principal if principal.is_a?(User) && principal.persisted?
  end

  def current_authentication_session
    session = request.env["lrail.authentication_session"]
    session if session.is_a?(AuthenticationSession) && session.persisted?
  end

  def current_organization
    @current_organization
  end

  def web_authenticated?
    current_principal && request.env["lrail.authentication_method"] == "cookie"
  end

  def require_web_session!
    return if web_authenticated? && current_authentication_session

    redirect_to auth_login_path, status: :see_other
  end
end
