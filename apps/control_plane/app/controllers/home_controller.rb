class HomeController < ApplicationController
  before_action :require_web_session!

  def index
    @organizations = current_principal.organizations.order(:created_at, :id)
    default = @organizations.first
    redirect_to team_path(default.slug) if default
  end
end
