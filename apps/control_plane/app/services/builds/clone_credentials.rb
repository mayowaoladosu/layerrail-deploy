module Builds
  class CloneCredentials
    class InvalidBuild < StandardError; end

    class ProviderFailure < StandardError
      attr_reader :code, :retryable

      def initialize(code:, retryable:)
        @code = code.to_s
        @retryable = retryable == true
        super("Git provider could not issue clone credentials")
      end
    end

    Result = Data.define(:credentials, :build)

    def self.call(build:, operation_id:, provider: nil)
      new(build:, operation_id:, provider:).call
    end

    def initialize(build:, operation_id:, provider:)
      @build = build
      @operation_id = operation_id.to_s
      @provider = provider
    end

    def call
      validate!
      installation = @build.deployment.service.repository_connection.git_installation
      provider = @provider || provider_for(installation)
      session_result = provider.open_session(
        installation_id: installation.provider_installation_id
      )
      raise_provider!(session_result) if session_result.failure?

      source = @build.deployment.source_snapshot
      credential_result = session_result.value.clone_credentials(
        repository_id: source.fetch("repository_id"),
        revision: source.fetch("commit_sha")
      )
      raise_provider!(credential_result) if credential_result.failure?
      credentials = credential_result.value
      raise InvalidBuild unless credentials.expires_at > Time.current + 60.seconds
      raise InvalidBuild unless valid_clone_url?(credentials.clone_url)
      raise InvalidBuild if credentials.clone_url.userinfo
      raise InvalidBuild if credentials.clone_url.query || credentials.clone_url.fragment

      Result.new(credentials:, build: @build)
    end

    private

    def validate!
      deployment = @build.deployment
      raise InvalidBuild unless @build.status == "running"
      raise InvalidBuild unless deployment.status == "building"
      raise InvalidBuild unless deployment.source_snapshot["type"] == "git"
      connection = deployment.service.repository_connection
      raise InvalidBuild unless connection&.status_active?
      raise InvalidBuild unless connection.organization_id == deployment.organization_id
      raise InvalidBuild unless connection.provider_repository_id == deployment.source_snapshot["repository_id"]

      command = OutboxEvent.find_by(
        organization_id: deployment.organization_id,
        resource_id: @build.id,
        event_type: "build.requested.v1"
      )
      raise InvalidBuild unless command
      raise InvalidBuild unless command.data["operation_id"] == @operation_id
      raise InvalidBuild unless command.data["build_id"] == @build.id
    end

    def provider_for(installation)
      case installation.provider
      when "github"
        GitProviders::Factory.github
      else
        raise InvalidBuild
      end
    end

    def valid_clone_url?(url)
      return true if url.is_a?(URI::HTTPS) && url.host.present?

      Rails.env.development? &&
        ENV["BUILD_CONTROLLER_E2E_PROVIDER_FILE"].present? &&
        url.is_a?(URI::HTTP) &&
        url.host == "git-fixture.lrail-system.svc.cluster.local" &&
        url.port == 8080
    end

    def raise_provider!(result)
      raise ProviderFailure.new(
        code: result.error.code,
        retryable: result.error.retryable
      )
    end
  end
end
