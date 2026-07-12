module RodauthHelpers
  def last_email_auth_url
    mail = ActionMailer::Base.deliveries.last
    body = mail.text_part ? mail.text_part.body.decoded : mail.body.decoded
    body[%r{https?://\S+/auth/verify\?key=[^\s]+}]
  end

  def last_email_auth_path
    URI(last_email_auth_url).request_uri
  end

  def last_email_auth_key
    URI.decode_www_form(URI(last_email_auth_url).query).to_h.fetch("key")
  end

  def sign_in_with_rodauth(user)
    post "/auth/login", params: { email: user.email }
    get last_email_auth_path
    follow_redirect!
    post "/auth/verify"
    follow_redirect!
  end
end

RSpec.configure do |config|
  config.include RodauthHelpers, type: :request
end
