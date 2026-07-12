class AuthenticationController < ApplicationController
  CHALLENGE_COOKIE_NAME = "lrail_login_challenge".freeze

  before_action :require_web_session!, only: %i[home logout]

  def home
    @organizations = current_principal.organizations.order(:created_at, :id)
  end

  def login
    redirect_to root_path if web_authenticated?
  end

  def create
    issued = Authentication::Challenges.issue(
      email: params[:email],
      ip: request.remote_ip
    )
    if issued.challenge
      AuthenticationMailer.with(challenge: issued.challenge).login_link.deliver_now
      Authentication::Challenges.mark_delivered(issued.challenge)
      @development_verification_url = auth_verify_url(token: issued.token) if Rails.env.development?
    end

    render :check_email, status: :accepted
  rescue Authentication::Challenges::InvalidEmail
    @error = "Enter a valid email address."
    render :login, status: :unprocessable_content
  end

  def verify
    challenge = Authentication::Challenges.verify(token: params[:token])
    cookies.encrypted[CHALLENGE_COOKIE_NAME] = {
      value: params[:token],
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      path: "/auth",
      expires: challenge.expires_at
    }
    redirect_to auth_confirm_path, status: :see_other
  rescue Authentication::Challenges::InvalidChallenge
    invalid_challenge
  end

  def confirm
    Authentication::Challenges.verify(token: cookies.encrypted[CHALLENGE_COOKIE_NAME])
  rescue Authentication::Challenges::InvalidChallenge
    invalid_challenge
  end

  def complete
    result = Authentication::Challenges.complete(
      token: cookies.encrypted[CHALLENGE_COOKIE_NAME],
      session_kind: :web,
      ip: request.remote_ip,
      user_agent: request.user_agent
    )
    cookies.delete(CHALLENGE_COOKIE_NAME, path: "/auth")
    set_authentication_cookie(result)
    redirect_to root_path, status: :see_other
  rescue Authentication::Challenges::InvalidChallenge
    invalid_challenge
  end

  def logout
    Authentication::Sessions.revoke(
      session: current_authentication_session,
      reason: "user_logout"
    )
    cookies.delete(Authentication::Middleware::COOKIE_NAME, path: "/")
    redirect_to auth_login_path, status: :see_other
  end

  private

  def set_authentication_cookie(result)
    cookies[Authentication::Middleware::COOKIE_NAME] = {
      value: result.token,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      path: "/",
      expires: result.session.expires_at
    }
  end

  def invalid_challenge
    cookies.delete(CHALLENGE_COOKIE_NAME, path: "/auth")
    @error = "This sign-in link is invalid or has expired. Request a new link."
    render :login, status: :unprocessable_content
  end
end
