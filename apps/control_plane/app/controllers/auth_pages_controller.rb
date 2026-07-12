class AuthPagesController < ApplicationController
  layout "authentication"

  def check_email
    redirect_to root_path and return if web_authenticated?

    @development_verification_url = session.delete(:development_verification_url) if Rails.env.development?
  end
end
