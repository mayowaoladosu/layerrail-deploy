class AuthenticationMailer < ApplicationMailer
  def login_link
    @challenge = params.fetch(:challenge)
    @verification_url = auth_verify_url(token: @challenge.token)

    mail(to: @challenge.email, subject: "Sign in to LayerRail Deploy")
  end
end
