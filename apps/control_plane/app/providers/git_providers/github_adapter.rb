module GitProviders
  class GithubAdapter < Adapter
    AccessToken = Data.define(:secret, :expires_at) do
      def to_h
        { expires_at: }
      end

      def inspect
        "#<#{self.class.name} secret=[REDACTED] expires_at=#{expires_at.iso8601}>"
      end
    end

    ERROR_MESSAGES = {
      installation_not_found: "Installation was not found",
      installation_inactive: "Installation is not active",
      invalid_credentials: "Provider credentials are invalid",
      invalid_request: "Provider request is invalid",
      provider_forbidden: "Provider access was denied",
      provider_unavailable: "Provider is unavailable",
      rate_limited: "Provider rate limit was exceeded",
      repository_not_found: "Repository was not found",
      revision_not_found: "Revision was not found",
      user_not_found: "Provider user was not found"
    }.freeze

    def initialize(
      app_id:,
      app_slug:,
      private_key:,
      webhook_secret:,
      cursor_secret:,
      transport: Http::NetTransport.new,
      clock: -> { Time.current }
    )
      @app_slug = app_slug.to_s
      @clock = clock
      @transport = transport
      @app_jwt = AppJwt.new(app_id:, private_key:, clock:)
      @cursor_codec = CursorCodec.new(secret: cursor_secret)
      @webhook_verifier = WebhookVerifier.new(secret: webhook_secret, clock:)
      @installation_cache = {}
    end

    def installation_setup(state:, redirect_uri:)
      redirect = URI(redirect_uri.to_s)
      return failure(:invalid_request) unless redirect.is_a?(URI::HTTPS) && state.present?

      url = URI("https://github.com/apps/#{@app_slug}/installations/new")
      url.query = URI.encode_www_form(state:, redirect_uri: redirect.to_s)

      Result.success(Types::InstallationSetup.new(url:, state:))
    rescue URI::InvalidURIError
      failure(:invalid_request)
    end

    def installation(id:)
      id = id.to_s
      cached = @installation_cache[id]
      return Result.success(cached) if cached&.status == "disconnected"

      response = app_request(:get, "/app/installations/#{escape(id)}")
      return response_failure(response, not_found: :installation_not_found) unless response.status == 200

      installation = map_installation(response.body)
      @installation_cache[id] = installation
      Result.success(installation)
    rescue Http::TransportError
      failure(:provider_unavailable, retryable: true)
    rescue KeyError, TypeError, URI::InvalidURIError
      failure(:provider_unavailable, retryable: true)
    end

    def open_session(installation_id:)
      installation_result = installation(id: installation_id)
      return installation_result if installation_result.failure?
      return failure(:installation_inactive) unless installation_result.value.status == "active"

      token_result = issue_access_token(installation_id.to_s)
      return token_result if token_result.failure?

      Result.success(
        GithubSession.new(
          installation_id: installation_id.to_s,
          transport: @transport,
          token_resolver: -> { issue_access_token(installation_id.to_s) },
          initial_token: token_result.value,
          installation_active: -> { @installation_cache[installation_id.to_s]&.status == "active" },
          cursor_codec: @cursor_codec,
          clock: @clock
        )
      )
    end

    def disconnect(installation_id:)
      installation_result = installation(id: installation_id)
      return installation_result if installation_result.failure?
      return installation_result if installation_result.value.status == "disconnected"

      response = app_request(:delete, "/app/installations/#{escape(installation_id)}")
      return response_failure(response, not_found: :installation_not_found) unless [ 204, 404 ].include?(response.status)

      value = installation_result.value
      disconnected = Types::Installation.new(
        id: value.id,
        account_id: value.account_id,
        account_login: value.account_login,
        account_type: value.account_type,
        status: "disconnected",
        permissions: value.permissions
      )
      @installation_cache[value.id] = disconnected

      Result.success(disconnected)
    rescue Http::TransportError
      failure(:provider_unavailable, retryable: true)
    end

    def map_user(access_token:)
      headers = { "Authorization" => "Bearer #{access_token}" }
      user_response = @transport.request(method: :get, path: "/user", headers:)
      return failure(:user_not_found) unless user_response.status == 200

      email_response = @transport.request(method: :get, path: "/user/emails", headers:)
      return failure(:user_not_found) unless email_response.status == 200

      email = Array(email_response.body).find { |item| item["primary"] == true && item["verified"] == true }
      return failure(:user_not_found) unless email

      Result.success(
        Types::ProviderUser.new(
          id: user_response.body.fetch("id"),
          login: user_response.body.fetch("login"),
          name: user_response.body["name"].presence || user_response.body.fetch("login"),
          email: email.fetch("email")
        )
      )
    rescue Http::TransportError
      failure(:provider_unavailable, retryable: true)
    rescue KeyError, TypeError
      failure(:user_not_found)
    end

    def verify_webhook(delivery_id:, event_type:, signature:, body:)
      @webhook_verifier.call(delivery_id:, event_type:, signature:, body:)
    end

    def inspect
      "#<#{self.class.name} app_slug=#{@app_slug.inspect} credentials=[REDACTED]>"
    end

    private

    def issue_access_token(installation_id)
      response = app_request(
        :post,
        "/app/installations/#{escape(installation_id)}/access_tokens",
        body: { "permissions" => { "contents" => "read", "metadata" => "read" } }
      )
      return response_failure(response, not_found: :installation_not_found) unless response.status == 201

      Result.success(
        AccessToken.new(
          secret: response.body.fetch("token").to_s.dup.freeze,
          expires_at: Time.iso8601(response.body.fetch("expires_at"))
        )
      )
    rescue Http::TransportError
      failure(:provider_unavailable, retryable: true)
    rescue KeyError, ArgumentError
      failure(:provider_unavailable, retryable: true)
    end

    def app_request(method, path, body: nil)
      @transport.request(
        method:,
        path:,
        headers: { "Authorization" => "Bearer #{@app_jwt.issue}" },
        body:
      )
    end

    def map_installation(body)
      account = body.fetch("account")
      status = body["suspended_at"].present? ? "suspended" : "active"

      Types::Installation.new(
        id: body.fetch("id"),
        account_id: account.fetch("id"),
        account_login: account.fetch("login"),
        account_type: account.fetch("type").to_s.downcase,
        status:,
        permissions: body.fetch("permissions", {})
      )
    end

    def response_failure(response, not_found:)
      case response.status
      when 401
        failure(:invalid_credentials)
      when 403
        retry_after = response.headers["retry-after"]&.to_i
        retry_after ? failure(:rate_limited, retryable: true, retry_after:) : failure(:provider_forbidden)
      when 404
        failure(not_found)
      when 422
        failure(:invalid_request)
      else
        failure(:provider_unavailable, retryable: true)
      end
    end

    def failure(code, retryable: false, retry_after: nil)
      Result.failure(
        code,
        message: ERROR_MESSAGES.fetch(code),
        retryable:,
        retry_after:
      )
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end
  end
end
