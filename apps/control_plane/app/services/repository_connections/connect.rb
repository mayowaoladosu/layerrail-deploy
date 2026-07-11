module RepositoryConnections
  class Connect
    def self.call(context:, provider:, installation:, service:, provider_repository_id:)
      new(context:, provider:, installation:, service:, provider_repository_id:).call
    end

    def initialize(context:, provider:, installation:, service:, provider_repository_id:)
      @context = context
      @provider = provider
      @installation = installation
      @service = service
      @provider_repository_id = provider_repository_id
    end

    def call
      candidate = RepositoryConnection.new(
        organization: @context&.organization,
        git_installation: @installation,
        service: @service,
        provider_repository_id: @provider_repository_id,
        owner: "pending",
        name: "pending",
        full_name: "pending/pending",
        default_branch: "pending",
        private: true,
        status: :active
      )
      authorize!(candidate)

      session_result = @provider.open_session(installation_id: @installation.provider_installation_id)
      return session_result if session_result.failure?

      repository_result = session_result.value.repository(repository_id: @provider_repository_id)
      return repository_result if repository_result.failure?

      repository = repository_result.value
      @service.with_lock do
        connection = RepositoryConnection.find_or_initialize_by(service: @service)
        connection.assign_attributes(
          organization: @context.organization,
          git_installation: @installation,
          project: @service.project,
          provider_repository_id: repository.id,
          owner: repository.owner,
          name: repository.name,
          full_name: repository.full_name,
          private: repository.private,
          default_branch: repository.default_branch,
          status: :active
        )
        connection.save!
        @service.update!(source_type: :git, source_reference: "#{@installation.provider}:#{repository.id}")

        GitProviders::Result.success(connection)
      end
    end

    private

    def authorize!(candidate)
      return if RepositoryConnectionPolicy.new(@context, candidate).create?

      raise Pundit::NotAuthorizedError, "not allowed to connect this repository"
    end
  end
end
