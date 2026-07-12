module Authentication
  class Sessions
    TOKEN_BYTES = 32
    DEFAULT_TTL = ENV.fetch("AUTH_TOKEN_TTL_DAYS", 30).to_i.days
    TOUCH_INTERVAL = 5.minutes

    Result = Data.define(:session, :token)
    Authenticated = Data.define(:session, :user)

    def self.issue(
      user:,
      kind:,
      ip:,
      user_agent:,
      assurance_level: :single_factor,
      issued_at: Time.current,
      expires_at: nil
    )
      normalized_kind = kind.to_s
      normalized_assurance_level = assurance_level.to_s
      raise ArgumentError unless normalized_kind.in?(AuthenticationSession::KINDS)
      raise ArgumentError unless normalized_assurance_level.in?(AuthenticationSession::ASSURANCE_LEVELS)
      raise ArgumentError unless user&.persisted?

      token = "lr_#{normalized_kind}_#{SecureRandom.urlsafe_base64(TOKEN_BYTES, false)}"
      expires_at ||= issued_at + DEFAULT_TTL
      session = AuthenticationSession.create!(
        user:,
        kind: normalized_kind,
        assurance_level: normalized_assurance_level,
        token_digest: TokenDigests.token(token),
        issued_at:,
        expires_at:,
        ip_digest: TokenDigests.context(ip),
        user_agent_digest: TokenDigests.context(user_agent)
      )

      Result.new(session:, token:)
    end

    def self.authenticate(token:, kind:, now: Time.current)
      raw_token = token.to_s
      normalized_kind = kind.to_s
      return unless raw_token.start_with?("lr_#{normalized_kind}_")
      return if raw_token.bytesize > 256

      session = AuthenticationSession.includes(:user).find_by(
        token_digest: TokenDigests.token(raw_token),
        kind: normalized_kind,
        revoked_at: nil
      )
      return unless session && session.expires_at > now && session.user.persisted?

      if session.last_used_at.nil? || session.last_used_at < now - TOUCH_INTERVAL
        session.update!(last_used_at: now)
      end

      Authenticated.new(session:, user: session.user)
    end

    def self.revoke(session:, reason:, now: Time.current)
      session.with_lock do
        return session if session.revoked_at

        session.update!(revoked_at: now, revoked_reason: reason.to_s.strip)
      end
      session
    end
  end
end
