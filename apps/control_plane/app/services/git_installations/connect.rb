module GitInstallations
  class Connect
    def self.call(context:, provider:, provider_name:, provider_installation_id:)
      new(context:, provider:, provider_name:, provider_installation_id:).call
    end

    def initialize(context:, provider:, provider_name:, provider_installation_id:)
      @context = context
      @provider = provider
      @provider_name = provider_name
      @provider_installation_id = provider_installation_id
    end

    def call
      candidate = GitInstallation.new(
        organization: @context&.organization,
        provider: @provider_name,
        provider_installation_id: @provider_installation_id,
        account_id: "pending",
        account_login: "pending",
        account_type: "organization",
        status: :active,
        permissions: {}
      )
      authorize!(candidate)

      provider_result = @provider.installation(id: @provider_installation_id)
      return provider_result if provider_result.failure?

      metadata = provider_result.value
      ApplicationRecord.transaction(requires_new: true) do
        lock_installation!
        installation = GitInstallation.find_or_initialize_by(
          provider: @provider_name,
          provider_installation_id: metadata.id
        )
        if installation.persisted? && installation.organization_id != @context.organization.id
          raise Pundit::NotAuthorizedError, "not allowed to move this Git installation"
        end
        installation.assign_attributes(
          organization: @context.organization,
          account_id: metadata.account_id,
          account_login: metadata.account_login,
          account_type: metadata.account_type,
          status: metadata.status,
          permissions: metadata.permissions
        )
        installation.save!

        GitProviders::Result.success(installation)
      end
    end

    private

    def authorize!(candidate)
      return if GitInstallationPolicy.new(@context, candidate).create?

      raise Pundit::NotAuthorizedError, "not allowed to connect this Git installation"
    end

    def lock_installation!
      key = "#{@provider_name}:#{@provider_installation_id}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
  end
end
