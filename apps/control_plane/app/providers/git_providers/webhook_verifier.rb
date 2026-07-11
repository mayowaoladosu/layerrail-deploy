require "openssl"

module GitProviders
  class WebhookVerifier
    MAX_BODY_BYTES = 2.megabytes

    def initialize(secret:, clock:)
      @secret = secret.to_s
      @clock = clock
    end

    def call(delivery_id:, event_type:, signature:, body:)
      return failure(:invalid_payload) unless body.is_a?(String)
      return failure(:payload_too_large) if body.bytesize > MAX_BODY_BYTES
      return failure(:invalid_payload) if delivery_id.blank?
      return failure(:invalid_signature) unless valid_signature?(signature, body)

      payload = JSON.parse(body)
      return failure(:invalid_payload) unless payload.is_a?(Hash)

      normalize(
        delivery_id: delivery_id.to_s,
        event_type: event_type.to_s,
        payload:
      )
    rescue JSON::ParserError
      failure(:invalid_payload)
    end

    def inspect
      "#<#{self.class.name} secret=[REDACTED]>"
    end

    private

    ERROR_MESSAGES = {
      invalid_payload: "Webhook payload is invalid",
      invalid_signature: "Webhook signature is invalid",
      payload_too_large: "Webhook payload is too large",
      unsupported_event: "Webhook event is not supported"
    }.freeze

    def failure(code)
      Result.failure(code, message: ERROR_MESSAGES.fetch(code))
    end

    def valid_signature?(signature, body)
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", @secret, body)}"

      signature.to_s.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected)
    end

    def normalize(delivery_id:, event_type:, payload:)
      case event_type
      when "push"
        normalize_push(delivery_id:, payload:)
      when "pull_request"
        normalize_pull_request(delivery_id:, payload:)
      when "installation"
        normalize_installation(delivery_id:, payload:)
      else
        failure(:unsupported_event)
      end
    end

    def normalize_push(delivery_id:, payload:)
      installation_id = payload.dig("installation", "id")
      repository_id = payload.dig("repository", "id")
      ref = payload["ref"]
      before_sha = payload["before"]
      after_sha = payload["after"]
      provider_user_id = payload.dig("pusher", "id")
      required = [ installation_id, repository_id, ref, before_sha, after_sha, provider_user_id ]
      return failure(:invalid_payload) if required.any?(&:blank?)

      success(
        delivery_id:,
        type: "git.push.v1",
        installation_id:,
        repository_id:,
        data: {
          "ref" => ref.delete_prefix("refs/heads/"),
          "before_sha" => before_sha,
          "after_sha" => after_sha,
          "provider_user_id" => provider_user_id.to_s
        }
      )
    end

    def normalize_pull_request(delivery_id:, payload:)
      installation_id = payload.dig("installation", "id")
      repository_id = payload.dig("repository", "id")
      action = payload["action"]
      number = payload["number"]
      head_ref = payload.dig("pull_request", "head", "ref")
      head_sha = payload.dig("pull_request", "head", "sha")
      base_ref = payload.dig("pull_request", "base", "ref")
      provider_user_id = payload.dig("sender", "id")
      merged = payload.dig("pull_request", "merged")
      required = [ installation_id, repository_id, action, number, head_ref, head_sha, base_ref, provider_user_id ]
      return failure(:invalid_payload) if required.any?(&:blank?)

      success(
        delivery_id:,
        type: "git.pull_request.v1",
        installation_id:,
        repository_id:,
        data: {
          "action" => action,
          "number" => number,
          "head_ref" => head_ref,
          "head_sha" => head_sha,
          "base_ref" => base_ref,
          "provider_user_id" => provider_user_id.to_s,
          "merged" => merged == true
        }
      )
    end

    def normalize_installation(delivery_id:, payload:)
      action = payload["action"]
      type = {
        "created" => "git.installation.connected.v1",
        "deleted" => "git.installation.disconnected.v1",
        "suspended" => "git.installation.suspended.v1",
        "unsuspended" => "git.installation.connected.v1"
      }[action]
      return failure(:unsupported_event) unless type

      installation_id = payload.dig("installation", "id")
      account_id = payload.dig("installation", "account", "id")
      account_login = payload.dig("installation", "account", "login")
      return failure(:invalid_payload) if [ installation_id, account_id, account_login ].any?(&:blank?)

      success(
        delivery_id:,
        type:,
        installation_id:,
        repository_id: nil,
        data: {
          "account_id" => account_id.to_s,
          "account_login" => account_login
        }
      )
    end

    def success(delivery_id:, type:, installation_id:, repository_id:, data:)
      Result.success(
        Types::WebhookEvent.new(
          delivery_id:,
          type:,
          installation_id: installation_id.to_s,
          repository_id: repository_id&.to_s,
          occurred_at: @clock.call,
          data:
        )
      )
    end
  end
end
