require "openssl"

module GitProviders
  class FakeSession < Session
    MAX_PAGE_SIZE = 100
    CREDENTIAL_TTL = 15.minutes

    def initialize(provider:, installation_id:, clock:, credential_seed:, cursor_codec:)
      @provider = provider
      @installation_id = installation_id
      @clock = clock
      @credential_seed = credential_seed
      @cursor_codec = cursor_codec
    end

    def repositories(cursor: nil, limit: 30)
      return inactive_failure unless active?

      paginate(
        @provider.repositories_for(@installation_id),
        scope: "repositories:#{@installation_id}",
        cursor:,
        limit:
      )
    end

    def branches(repository_id:, cursor: nil, limit: 30)
      return inactive_failure unless active?
      return repository_failure unless authorized_repository(repository_id)

      paginate(
        @provider.branches_for(repository_id.to_s),
        scope: "branches:#{@installation_id}:#{repository_id}",
        cursor:,
        limit:
      )
    end

    def commits(repository_id:, ref:, cursor: nil, limit: 30)
      return inactive_failure unless active?
      return repository_failure unless authorized_repository(repository_id)

      commits = @provider.commits_for(repository_id.to_s, ref.to_s)
      return failure(:revision_not_found, "Revision was not found") if commits.empty?

      paginate(
        commits,
        scope: "commits:#{@installation_id}:#{repository_id}:#{ref}",
        cursor:,
        limit:
      )
    end

    def clone_credentials(repository_id:, revision:)
      return inactive_failure unless active?

      repository = authorized_repository(repository_id)
      return repository_failure unless repository
      return failure(:revision_not_found, "Revision was not found") unless known_revision?(repository.id, revision)

      issued_at = @clock.call
      secret = OpenSSL::HMAC.hexdigest(
        "SHA256",
        @credential_seed,
        [ @installation_id, repository.id, revision, issued_at.iso8601 ].join(":")
      )

      Result.success(
        Types::CloneCredentials.new(
          clone_url: "https://git.example.test/#{repository.full_name}.git",
          username: "x-access-token",
          secret:,
          expires_at: issued_at + CREDENTIAL_TTL
        )
      )
    end

    private

    def active?
      @provider.active_installation?(@installation_id)
    end

    def authorized_repository(repository_id)
      @provider.repositories_for(@installation_id).find { |repository| repository.id == repository_id.to_s }
    end

    def known_revision?(repository_id, revision)
      branches = @provider.branches_for(repository_id)
      return true if branches.any? { |branch| branch.name == revision || branch.sha == revision }

      branches.any? do |branch|
        @provider.commits_for(repository_id, branch.name).any? { |commit| commit.sha == revision }
      end
    end

    def paginate(items, scope:, cursor:, limit:)
      return failure(:invalid_request, "Provider request is invalid") unless valid_limit?(limit)

      offset = if cursor.nil?
        0
      else
        @cursor_codec.decode(cursor, scope:)
      end
      return failure(:invalid_cursor, "Pagination cursor is invalid") if offset.nil?

      page_items = items.slice(offset, limit) || []
      next_offset = offset + page_items.length
      next_cursor = if next_offset < items.length
        @cursor_codec.encode(scope:, offset: next_offset)
      end

      Result.success(Types::Page.new(items: page_items, next_cursor:))
    end

    def valid_limit?(limit)
      limit.is_a?(Integer) && limit.between?(1, MAX_PAGE_SIZE)
    end

    def inactive_failure
      failure(:installation_inactive, "Installation is not active")
    end

    def repository_failure
      failure(:repository_not_found, "Repository was not found")
    end

    def failure(code, message)
      Result.failure(code, message:)
    end
  end
end
