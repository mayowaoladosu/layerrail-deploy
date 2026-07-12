module Authentication
  class RodauthSessions
    class InvalidToken < StandardError; end

    Result = Data.define(:user, :organization, :token, :expires_at)

    def self.exchange(token)
      rodauth = Rodauth::Rails.rodauth(session: {})
      jwt = rodauth.exchange_email_auth_key(token.to_s)
      user = User.find(rodauth.account_id)

      Result.new(
        user:,
        organization: user.organizations.order(:created_at, :id).first,
        token: jwt,
        expires_at: Time.current + RodauthMain::SESSION_TTL
      )
    rescue ActiveRecord::RecordNotFound, Rodauth::InternalRequestError
      raise InvalidToken
    end

    def self.issue(user)
      rodauth = Rodauth::Rails.rodauth(account: user, session: {})

      Result.new(
        user:,
        organization: user.organizations.order(:created_at, :id).first,
        token: rodauth.issue_api_session,
        expires_at: Time.current + RodauthMain::SESSION_TTL
      )
    end

    def self.revoke(token)
      validator = Rodauth::Rails.rodauth(
        env: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_AUTHORIZATION" => "Bearer #{token}"
        }
      )
      rodauth_session = validator.verified_jwt_session
      return false unless rodauth_session

      RodauthApp.rodauth.internal_request_eval(
        account_id: rodauth_session.fetch(:account_id),
        session: rodauth_session
      ) do
        next false unless currently_active_session?

        remove_current_session
        true
      end
    rescue KeyError
      false
    end
  end
end
