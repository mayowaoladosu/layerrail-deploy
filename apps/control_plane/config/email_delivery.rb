module ControlPlane
  module EmailDelivery
    module_function

    def configure(mailer, environment:, root:, env: ENV)
      if smtp_configured?(env)
        mailer.delivery_method = :smtp
        mailer.smtp_settings = smtp_settings(env)
      elsif present?(env["RESEND_API_KEY"])
        mailer.delivery_method = :resend
      elsif environment.to_s == "development"
        mailer.delivery_method = :file
        mailer.file_settings = { location: root.join("tmp/mails") }
      else
        raise KeyError, "Set RESEND_API_KEY or complete SMTP settings for email delivery"
      end
    end

    def smtp_configured?(env)
      %w[SMTP_HOST SMTP_USERNAME SMTP_PASSWORD].all? { |key| present?(env[key]) }
    end

    def smtp_settings(env)
      {
        address: env.fetch("SMTP_HOST"),
        port: env.fetch("SMTP_PORT", 587).to_i,
        user_name: env.fetch("SMTP_USERNAME"),
        password: env.fetch("SMTP_PASSWORD"),
        authentication: :plain,
        enable_starttls_auto: true
      }
    end

    def present?(value)
      value && !value.strip.empty?
    end
  end
end
