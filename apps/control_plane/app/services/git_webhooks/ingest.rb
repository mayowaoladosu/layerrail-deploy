module GitWebhooks
  class Ingest
    Result = Data.define(:message, :replayed, :ignored)

    def self.call(provider:, provider_name:, delivery_id:, event_type:, signature:, body:)
      new(
        provider:,
        provider_name:,
        delivery_id:,
        event_type:,
        signature:,
        body:
      ).call
    end

    def initialize(provider:, provider_name:, delivery_id:, event_type:, signature:, body:)
      @provider = provider
      @provider_name = provider_name
      @delivery_id = delivery_id
      @event_type = event_type
      @signature = signature
      @body = body
    end

    def call
      provider_result = @provider.verify_webhook(
        delivery_id: @delivery_id,
        event_type: @event_type,
        signature: @signature,
        body: @body
      )
      return provider_result if provider_result.failure?

      event = provider_result.value
      installation = GitInstallation.find_by(
        provider: @provider_name,
        provider_installation_id: event.installation_id
      )
      return GitProviders::Result.success(Result.new(message: nil, replayed: false, ignored: true)) unless installation

      digest = Digest::SHA256.hexdigest(@body)
      ApplicationRecord.transaction(requires_new: true) do
        lock_delivery!

        existing = GitWebhookInbox.find_by(provider: @provider_name, delivery_id: event.delivery_id)
        return replay(existing, digest:) if existing

        message = GitWebhookInbox.create!(
          organization: installation.organization,
          git_installation: installation,
          provider: @provider_name,
          delivery_id: event.delivery_id,
          event_type: event.type,
          provider_repository_id: event.repository_id,
          occurred_at: event.occurred_at,
          payload_digest: digest,
          data: event.data,
          status: immediate_event?(event.type) ? :processed : :pending,
          processed_at: immediate_event?(event.type) ? Time.current : nil
        )
        apply_immediate_event!(installation:, event:)

        GitProviders::Result.success(Result.new(message:, replayed: false, ignored: false))
      end
    end

    private

    def lock_delivery!
      lock_key = "#{@provider_name}:#{@delivery_id}"
      quoted_key = ApplicationRecord.connection.quote(lock_key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end

    def replay(existing, digest:)
      if existing.payload_digest != digest
        return GitProviders::Result.failure(
          :delivery_conflict,
          message: "Webhook delivery conflicts with an existing delivery"
        )
      end

      GitProviders::Result.success(Result.new(message: existing, replayed: true, ignored: false))
    end

    def immediate_event?(event_type)
      event_type.in?(
        %w[
          git.installation.connected.v1
          git.installation.disconnected.v1
          git.installation.suspended.v1
          git.repositories.changed.v1
          git.repository.changed.v1
        ]
      )
    end

    def apply_immediate_event!(installation:, event:)
      case event.type
      when "git.installation.connected.v1"
        installation.update!(status: :active)
      when "git.installation.suspended.v1"
        installation.update!(status: :suspended)
      when "git.installation.disconnected.v1"
        installation.update!(status: :disconnected)
        installation.repository_connections.update_all(status: "disconnected", updated_at: Time.current)
      when "git.repositories.changed.v1"
        apply_repository_selection!(installation:, event:)
      when "git.repository.changed.v1"
        apply_repository_change!(installation:, event:)
      end
    end

    def apply_repository_selection!(installation:, event:)
      status = event.data.fetch("action") == "added" ? "active" : "removed"
      installation.repository_connections
        .where(provider_repository_id: event.data.fetch("repository_ids"))
        .update_all(status:, updated_at: Time.current)
    end

    def apply_repository_change!(installation:, event:)
      connection = installation.repository_connections.find_by(
        provider_repository_id: event.repository_id
      )
      return unless connection

      case event.data.fetch("action")
      when "renamed"
        full_name = event.data.fetch("full_name")
        owner, name = full_name.split("/", 2)
        connection.update!(owner:, name:, full_name:)
      when "deleted", "transferred"
        connection.update!(status: :removed)
      end
    end
  end
end
