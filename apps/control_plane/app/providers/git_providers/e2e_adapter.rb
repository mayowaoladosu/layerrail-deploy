module GitProviders
  class E2eAdapter < Adapter
    MAX_CONFIG_BYTES = 64.kilobytes
    CREDENTIAL_TTL = 15.minutes

    class InvalidConfiguration < StandardError; end

    def initialize(path:, clock: -> { Time.current })
      raise InvalidConfiguration unless Rails.env.development?

      @path = Pathname(path).expand_path
      @clock = clock
    end

    def open_session(installation_id:)
      config = load_config
      return failure(:installation_not_found) unless installation_id.to_s == config.fetch("installation_id")

      Result.success(E2eSession.new(config:, clock: @clock))
    rescue InvalidConfiguration
      failure(:provider_unavailable, retryable: true)
    end

    def inspect
      "#<#{self.class.name} path=#{@path} credentials=[REDACTED]>"
    end

    private

    def load_config
      raise InvalidConfiguration unless @path.absolute? && @path.file?
      raise InvalidConfiguration if @path.size > MAX_CONFIG_BYTES

      value = JSON.parse(@path.read)
      raise InvalidConfiguration unless value.is_a?(Hash)
      raise InvalidConfiguration unless value.keys.sort == %w[installation_id repositories secret username]
      raise InvalidConfiguration unless value["installation_id"].is_a?(String) && value["installation_id"].present?
      raise InvalidConfiguration unless value["username"].is_a?(String) && value["username"].bytesize.between?(1, 255)
      raise InvalidConfiguration unless value["secret"].is_a?(String) && value["secret"].bytesize.between?(32, 4096)
      raise InvalidConfiguration unless value["repositories"].is_a?(Hash) && value["repositories"].size.between?(1, 16)

      value.fetch("repositories").each_value do |repository|
        raise InvalidConfiguration unless repository.is_a?(Hash)
        raise InvalidConfiguration unless repository.keys.sort == %w[clone_url commit]
        raise InvalidConfiguration unless repository["commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
        uri = URI(repository["clone_url"].to_s)
        local_fixture = uri.is_a?(URI::HTTP) &&
          !uri.is_a?(URI::HTTPS) &&
          uri.host == "git-fixture.lrail-system.svc.cluster.local" &&
          uri.port == 8080
        raise InvalidConfiguration unless uri.is_a?(URI::HTTPS) || local_fixture
        raise InvalidConfiguration unless uri.userinfo.nil?
        raise InvalidConfiguration unless uri.query.nil? && uri.fragment.nil?
        raise InvalidConfiguration if repository["clone_url"].each_byte.any? { |byte| byte < 32 || byte == 127 }
      rescue URI::InvalidURIError
        raise InvalidConfiguration
      end
      value
    rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError
      raise InvalidConfiguration
    end

    def failure(code, retryable: false)
      Result.failure(
        code,
        message: "E2E Git provider is unavailable",
        retryable:
      )
    end

    class E2eSession < Session
      def initialize(config:, clock:)
        @config = config
        @clock = clock
      end

      def clone_credentials(repository_id:, revision:)
        repository = @config.fetch("repositories")[repository_id.to_s]
        unless repository && repository.fetch("commit") == revision.to_s
          return Result.failure(
            :revision_not_found,
            message: "Revision was not found"
          )
        end

        Result.success(
          Types::CloneCredentials.new(
            clone_url: repository.fetch("clone_url"),
            username: @config.fetch("username"),
            secret: @config.fetch("secret"),
            expires_at: @clock.call + CREDENTIAL_TTL
          )
        )
      end

      def inspect
        "#<#{self.class.name} credentials=[REDACTED]>"
      end
    end
  end
end
