require "sequel/core"

class RodauthMain < Rodauth::Rails::Auth
  GENERIC_EMAIL_NOTICE = "If the address can sign in, a one-time link has been sent.".freeze
  SESSION_TTL = ENV.fetch("AUTH_TOKEN_TTL_DAYS", 30).to_i.days.to_i
  EMAIL_AUTH_TTL = ENV.fetch("MAGIC_LINK_TTL_SECONDS", 900).to_i
  JWT_ISSUER = "layerrail-control-plane".freeze
  JWT_AUDIENCE = "layerrail-api".freeze

  configure do
    github_client_id = ENV["GITHUB_APP_CLIENT_ID"].to_s
    github_client_secret = ENV["GITHUB_APP_CLIENT_SECRET"].to_s
    google_client_id = ENV["GOOGLE_CLIENT_ID"].to_s
    google_client_secret = ENV["GOOGLE_CLIENT_SECRET"].to_s
    features = %i[
      login
      logout
      email_auth
      active_sessions
      internal_request
      path_class_methods
      jwt
    ]
    github_enabled = github_client_id.present? && github_client_secret.present?
    google_enabled = google_client_id.present? && google_client_secret.present?
    features << :omniauth if github_enabled || google_enabled
    enable(*features)

    db Sequel.postgres(extensions: :activerecord_connection, keep_reference: false)
    convert_token_id_to_integer? false

    accounts_table :users
    login_column :email
    account_password_hash_column :password_hash
    email_auth_table :user_email_auth_keys
    active_sessions_table :user_active_session_keys
    active_sessions_account_id_column :user_id
    rails_account_model { User }

    prefix "/auth"
    email_auth_route "verify"
    email_auth_request_route "request-link"
    login_param "email"
    normalize_login { |login| login.to_s.strip.downcase }
    require_bcrypt? false
    skip_status_checks? true
    force_email_auth? true

    rails_controller { RodauthController }
    title_instance_variable :@page_title
    login_page_title "Sign in"
    login_button "Continue with email"
    logout_button "Sign out"
    email_auth_page_title "Finish signing in"

    base_url "#{ENV.fetch("CONTROL_PLANE_SCHEME", "http")}://#{ENV.fetch("CONTROL_PLANE_HOST", "control.localhost")}"
    domain ENV.fetch("CONTROL_PLANE_HOST", "control.localhost").split(":", 2).first
    login_redirect "/"
    logout_redirect { login_path }
    active_sessions_redirect { login_path }
    login_return_to_requested_location? true

    session_inactivity_deadline nil
    session_lifetime_deadline SESSION_TTL
    email_auth_deadline_interval(seconds: EMAIL_AUTH_TTL)
    email_auth_skip_resend_email_within 60
    email_auth_email_sent_notice_flash GENERIC_EMAIL_NOTICE
    email_auth_email_sent_redirect "/auth/check-email"
    email_auth_email_recently_sent_error_flash GENERIC_EMAIL_NOTICE
    email_auth_email_recently_sent_redirect "/auth/check-email"
    email_auth_request_error_flash GENERIC_EMAIL_NOTICE
    no_matching_email_auth_key_error_flash "This sign-in link is invalid or has expired. Request a new link."
    email_auth_error_flash "This sign-in link is invalid or has expired. Request a new link."
    email_auth_email_subject "Your LayerRail Deploy sign-in link"

    only_json? false
    json_response_custom_error_status? false
    json_response_error_status 401
    jwt_secret { hmac_secret }
    jwt_session_key "session"
    jwt_decode_opts do
      {
        verify_iss: true,
        iss: JWT_ISSUER,
        verify_aud: true,
        aud: JWT_AUDIENCE
      }
    end
    jwt_session_hash do
      super().merge(
        "iss" => JWT_ISSUER,
        "aud" => JWT_AUDIENCE,
        "iat" => Time.now.to_i,
        "exp" => Time.now.to_i + SESSION_TTL
      )
    end

    account_from_login do |login|
      normalized_login = normalize_login(login)
      next unless Authentication::RequestLimiter.allow?(
        email: normalized_login,
        ip: request.env["REMOTE_ADDR"]
      )
      next unless Authentication::IdentityBootstrap.prepare(normalized_login)

      super(normalized_login)
    end

    before_email_auth_route do
      next unless request.post?

      token = session[email_auth_session_key] || param_or_nil(email_auth_key_param)
      unless prepare_email_auth_login(token)
        set_redirect_error_flash email_auth_error_flash
        redirect login_path
      end
    end

    before_login do
      next if Authentication::IdentityBootstrap.activate(account_id)

      remove_email_auth_key
      set_redirect_error_flash "Sign-in is not available for this account."
      redirect login_path
    end

    after_no_matching_login do
      set_notice_flash GENERIC_EMAIL_NOTICE
      redirect email_auth_email_sent_redirect
    end

    after_email_auth_request do
      if Rails.env.development? && !internal_request?
        session[:development_verification_url] = email_auth_email_link
      end
    end

    create_email_auth_email do
      RodauthMailer.email_auth(
        self.class.configuration_name,
        account_id,
        email_auth_key_value
      )
    end
    send_email do |email|
      db.after_commit { email.deliver_now }
    end

    if features.include?(:omniauth)
      omniauth_identities_table :user_identities
      omniauth_identities_account_id_column :user_id
      omniauth_prefix ""
      if github_enabled
        omniauth_provider :github,
          github_client_id,
          github_client_secret,
          scope: "user:email"
      end
      if google_enabled
        omniauth_provider :google_oauth2,
          google_client_id,
          google_client_secret,
          name: :google
      end
      omniauth_create_account? { !Organization.exists? }
      omniauth_login_failure_redirect { login_path }
      omniauth_failure_redirect { login_path }
      omniauth_login_no_matching_account_error_flash "Sign-in is not available for this provider account."
      omniauth_failure_error_flash "Provider sign-in could not be completed. Try again."
      account_from_omniauth do
        email = omniauth_email.to_s.strip.downcase
        account_table_ds.where(Sequel.function(:lower, login_column) => email).first
      end
      before_omniauth_create_account do
        now = Time.current
        account[:id] = SecureRandom.uuid_v7
        account[login_column] = omniauth_email.to_s.strip.downcase
        account[:name] = Authentication::IdentityBootstrap.display_name(
          omniauth_name.presence || omniauth_email
        )
        account[:authentication_state] = "bootstrap_candidate"
        account[:created_at] = now
        account[:updated_at] = now
      end
      omniauth_identity_insert_hash do
        super().merge(
          id: SecureRandom.uuid_v7,
          created_at: Time.current,
          updated_at: Time.current
        )
      end
    end

    # Keep non-HTTP API/E2E session operations inside the pinned Rodauth extension.
    auth_class_eval do
      def prepare_email_auth_login(token)
        return false unless token && account_from_email_auth_key(token)
        return false unless Authentication::LoginClaims.claim(token)

        unless Authentication::IdentityBootstrap.activate(account_id)
          remove_email_auth_key
          return false
        end

        true
      end

      def exchange_email_auth_key(token)
        raise Rodauth::InternalRequestError, "invalid email authentication key" unless prepare_email_auth_login(token)

        transaction do
          before_login
          login_session("email_auth")
          after_login
        end
        session_jwt
      end

      def issue_api_session
        transaction do
          before_login
          login_session("internal")
          after_login
        end
        session_jwt
      end

      def verified_jwt_session
        return unless valid_jwt?

        jwt_payload.fetch("session").to_h.transform_keys(&:to_sym)
      rescue KeyError
        nil
      end
    end
  end
end
