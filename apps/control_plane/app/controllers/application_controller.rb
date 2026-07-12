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
    injected = request.env["lrail.authenticated_principal"]
    return injected if Rails.env.test? && injected.is_a?(User) && injected.persisted?
    return unless rodauth.logged_in?

    account = rodauth.rails_account
    account if account.is_a?(User) && account.persisted?
  end

  def current_organization
    @current_organization
  end

  def web_authenticated?
    current_principal && !rodauth.use_jwt?
  end

  def require_web_session!
    return if web_authenticated?

    redirect_to rodauth.login_path, status: :see_other
  end
end
