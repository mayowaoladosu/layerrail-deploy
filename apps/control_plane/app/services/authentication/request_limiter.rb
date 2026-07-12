module Authentication
  class RequestLimiter
    WINDOW = 15.minutes
    MAX_PER_EMAIL = 5
    MAX_PER_IP = 20

    def self.allow?(email:, ip:, now: Time.current)
      email_digest = digest(email)
      ip_digest = digest(ip)

      ApplicationRecord.transaction(requires_new: true) do
        [ "auth-email:#{email_digest}", ("auth-ip:#{ip_digest}" if ip_digest) ]
          .compact
          .sort
          .each { |key| advisory_lock!(key) }

        cutoff = now - WINDOW
        if AuthenticationRequestAttempt.where(email_digest:, created_at: cutoff..).count >= MAX_PER_EMAIL
          next false
        end
        if ip_digest && AuthenticationRequestAttempt.where(ip_digest:, created_at: cutoff..).count >= MAX_PER_IP
          next false
        end

        AuthenticationRequestAttempt.create!(
          email_digest:,
          ip_digest:,
          created_at: now,
          updated_at: now
        )
        true
      end
    end

    def self.digest(value)
      input = value.to_s
      return if input.blank?

      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, input)
    end
    private_class_method :digest

    def self.advisory_lock!(key)
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
    private_class_method :advisory_lock!
  end
end
