module GitProviders
  class FakeAdapter < Adapter
    def initialize(
      clock:,
      webhook_secret:,
      credential_seed:,
      installations:,
      repositories:,
      branches:,
      commits:,
      users_by_token:
    )
      @clock = clock
      @webhook_secret = webhook_secret
      @credential_seed = credential_seed
      @installations = installations.index_by(&:id)
      @repositories = repositories.transform_values { |items| items.sort_by(&:full_name).freeze }
      @branches = branches.transform_values { |items| items.sort_by(&:name).freeze }
      @commits = commits.transform_values do |items|
        items.sort_by { |commit| [ -commit.authored_at.to_f, commit.sha ] }.freeze
      end
      @users_by_token = users_by_token.dup
      @cursor_codec = CursorCodec.new(secret: credential_seed)
      @webhook_verifier = WebhookVerifier.new(secret: webhook_secret, clock:)
    end

    def installation_setup(state:, redirect_uri:)
      redirect = URI(redirect_uri.to_s)
      return failure(:invalid_request) unless redirect.is_a?(URI::HTTPS) && state.present?

      url = URI("https://git.example.test/install")
      url.query = URI.encode_www_form(state:, redirect_uri: redirect.to_s)

      Result.success(Types::InstallationSetup.new(url:, state:))
    rescue URI::InvalidURIError
      failure(:invalid_request)
    end

    def installation(id:)
      value = @installations[id.to_s]
      return failure(:installation_not_found) unless value

      Result.success(value)
    end

    def open_session(installation_id:)
      value = @installations[installation_id.to_s]
      return failure(:installation_not_found) unless value
      return failure(:installation_inactive) unless value.status == "active"

      Result.success(
        FakeSession.new(
          provider: self,
          installation_id: value.id,
          clock: @clock,
          credential_seed: @credential_seed,
          cursor_codec: @cursor_codec
        )
      )
    end

    def disconnect(installation_id:)
      value = @installations[installation_id.to_s]
      return failure(:installation_not_found) unless value
      return Result.success(value) if value.status == "disconnected"

      disconnected = Types::Installation.new(
        id: value.id,
        account_id: value.account_id,
        account_login: value.account_login,
        account_type: value.account_type,
        status: "disconnected",
        permissions: value.permissions
      )
      @installations[value.id] = disconnected

      Result.success(disconnected)
    end

    def map_user(access_token:)
      value = @users_by_token[access_token.to_s]
      return failure(:user_not_found) unless value

      Result.success(value)
    end

    def verify_webhook(delivery_id:, event_type:, signature:, body:)
      @webhook_verifier.call(delivery_id:, event_type:, signature:, body:)
    end

    def active_installation?(installation_id)
      @installations[installation_id]&.status == "active"
    end

    def repositories_for(installation_id)
      @repositories.fetch(installation_id, EMPTY_ARRAY)
    end

    def branches_for(repository_id)
      @branches.fetch(repository_id, EMPTY_ARRAY)
    end

    def commits_for(repository_id, ref)
      @commits.fetch([ repository_id, ref ], EMPTY_ARRAY)
    end

    def inspect
      "#<#{self.class.name} installations=#{@installations.size} credentials=[REDACTED]>"
    end

    private

    EMPTY_ARRAY = [].freeze

    ERROR_MESSAGES = {
      installation_not_found: "Installation was not found",
      installation_inactive: "Installation is not active",
      invalid_cursor: "Pagination cursor is invalid",
      invalid_payload: "Webhook payload is invalid",
      invalid_request: "Provider request is invalid",
      invalid_signature: "Webhook signature is invalid",
      payload_too_large: "Webhook payload is too large",
      repository_not_found: "Repository was not found",
      revision_not_found: "Revision was not found",
      unsupported_event: "Webhook event is not supported",
      user_not_found: "Provider user was not found"
    }.freeze

    def failure(code)
      Result.failure(code, message: ERROR_MESSAGES.fetch(code))
    end
  end
end
