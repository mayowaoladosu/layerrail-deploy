class ApplicationMailer < ActionMailer::Base
  default from: -> {
    name = ENV.fetch("EMAIL_SENDER_NAME", "LayerRail Deploy")
    address = ENV.fetch("EMAIL_SENDER_ADDRESS", "no-reply@localhost")
    "#{name} <#{address}>"
  }
  layout "mailer"
end
