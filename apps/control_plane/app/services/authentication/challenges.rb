module Authentication
  class Challenges
    class InvalidChallenge < StandardError; end
    class InvalidEmail < StandardError; end

    TOKEN_BYTES = 32
    DEFAULT_TTL = ENV.fetch("MAGIC_LINK_TTL_SECONDS", 900).to_i.seconds
    RATE_WINDOW = 15.minutes
    MAX_PER_EMAIL = 5
    MAX_PER_IP = 20

    Issued = Data.define(:challenge, :token, :rate_limited)
    Completed = Data.define(:user, :organization, :session, :token)

    def self.issue(email:, ip:, issued_at: Time.current, expires_at: nil)
      normalized_email = normalize_email(email)
      ip_digest = TokenDigests.context(ip)
      expires_at ||= issued_at + DEFAULT_TTL

      ApplicationRecord.transaction(requires_new: true) do
        [ "challenge:email:#{normalized_email}", ("challenge:ip:#{ip_digest}" if ip_digest) ]
          .compact
          .sort
          .each { |key| advisory_lock!(key) }
        if rate_limited?(email: normalized_email, ip_digest:, now: issued_at)
          return Issued.new(challenge: nil, token: nil, rate_limited: true)
        end

        token = "lr_challenge_#{SecureRandom.urlsafe_base64(TOKEN_BYTES, false)}"
        challenge = LoginChallenge.create!(
          email: normalized_email,
          purpose: :email_login,
          token:,
          token_digest: TokenDigests.token(token),
          requested_ip_digest: ip_digest,
          expires_at:,
          created_at: issued_at,
          updated_at: issued_at
        )

        Issued.new(challenge:, token:, rate_limited: false)
      end
    end

    def self.complete(token:, session_kind:, ip:, user_agent:, now: Time.current)
      raw_token = token.to_s
      raise InvalidChallenge unless raw_token.start_with?("lr_challenge_") && raw_token.bytesize <= 256

      ApplicationRecord.transaction(requires_new: true) do
        challenge = LoginChallenge.find_by(token_digest: TokenDigests.token(raw_token))
        raise InvalidChallenge unless challenge

        challenge.lock!
        raise InvalidChallenge unless valid_challenge?(challenge, raw_token:, now:)

        advisory_lock!("identity:#{challenge.email}")
        advisory_lock!("authentication:bootstrap")
        user = User.find_by(email: challenge.email)
        if user.nil?
          raise InvalidChallenge if Organization.exists?

          user = User.create!(email: challenge.email, name: display_name(challenge.email))
        end
        organization = user.organizations.order(:created_at, :id).first
        if organization.nil? && !Organization.exists?
          organization = Organizations::Create.call(
            principal: user,
            name: "#{user.name.first(100)} Organization"
          ).organization
        end
        issued = Sessions.issue(
          user:,
          kind: session_kind,
          ip:,
          user_agent:,
          issued_at: now
        )
        challenge.update!(consumed_at: now, token: nil)

        Completed.new(
          user:,
          organization:,
          session: issued.session,
          token: issued.token
        )
      end
    end

    def self.verify(token:, now: Time.current)
      raw_token = token.to_s
      raise InvalidChallenge unless raw_token.start_with?("lr_challenge_") && raw_token.bytesize <= 256

      challenge = LoginChallenge.find_by(token_digest: TokenDigests.token(raw_token))
      raise InvalidChallenge unless challenge && valid_challenge?(challenge, raw_token:, now:)

      challenge
    end

    def self.mark_delivered(challenge, now: Time.current)
      challenge.update!(delivered_at: now) unless challenge.delivered_at
      challenge
    end

    def self.normalize_email(value)
      email = value.to_s.strip.downcase
      valid = email.present? && email.length <= 320 && URI::MailTo::EMAIL_REGEXP.match?(email)
      raise InvalidEmail unless valid

      email
    end
    private_class_method :normalize_email

    def self.rate_limited?(email:, ip_digest:, now:)
      window = now - RATE_WINDOW
      return true if LoginChallenge.where(email:).where(created_at: window..).count >= MAX_PER_EMAIL
      return false unless ip_digest

      LoginChallenge.where(requested_ip_digest: ip_digest).where(created_at: window..).count >= MAX_PER_IP
    end
    private_class_method :rate_limited?

    def self.valid_challenge?(challenge, raw_token:, now:)
      challenge.purpose == "email_login" &&
        challenge.consumed_at.nil? &&
        challenge.expires_at > now &&
        challenge.token.present? &&
        ActiveSupport::SecurityUtils.secure_compare(challenge.token, raw_token)
    end
    private_class_method :valid_challenge?

    def self.display_name(email)
      value = email.split("@", 2).first.tr("._-", " ").squish.titleize.first(120)
      value.presence || "LayerRail User"
    end
    private_class_method :display_name

    def self.advisory_lock!(key)
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
    private_class_method :advisory_lock!
  end
end
