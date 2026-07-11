module GitProviders
  class GithubSession < Session
    MAX_PAGE_SIZE = 100

    def initialize(installation_id:, transport:, token_resolver:, initial_token:, installation_active:, cursor_codec:, clock:)
      @installation_id = installation_id
      @transport = transport
      @token_resolver = token_resolver
      @access_token = initial_token
      @installation_active = installation_active
      @cursor_codec = cursor_codec
      @clock = clock
    end

    def repositories(cursor: nil, limit: 30)
      return installation_inactive unless @installation_active.call

      offset = decode_offset(cursor, scope: cursor_scope("repositories", limit:))
      return invalid_cursor if offset.nil?
      return invalid_request unless valid_limit?(limit) && (offset % limit).zero?

      response = installation_request(
        :get,
        "/installation/repositories",
        query: { per_page: limit, page: (offset / limit) + 1 }
      )
      return response if response.is_a?(Result)

      items = response.body.fetch("repositories").map { |item| map_repository(item) }
      total_count = response.body.fetch("total_count")
      Result.success(
        Types::Page.new(
          items:,
          next_cursor: next_cursor(
            scope: cursor_scope("repositories", limit:),
            offset:,
            count: items.length,
            total_count:
          )
        )
      )
    rescue KeyError, TypeError, URI::InvalidURIError
      provider_unavailable
    end

    def repository(repository_id:)
      return installation_inactive unless @installation_active.call

      result = authorized_repository(repository_id)
      return result if result.failure?

      Result.success(map_repository(result.value))
    rescue KeyError, TypeError, URI::InvalidURIError
      provider_unavailable
    end

    def branches(repository_id:, cursor: nil, limit: 30)
      return installation_inactive unless @installation_active.call

      offset = decode_offset(cursor, scope: cursor_scope("branches", repository_id, limit:))
      return invalid_cursor if offset.nil?
      return invalid_request unless valid_limit?(limit) && (offset % limit).zero?
      repository_result = authorized_repository(repository_id)
      return repository_result if repository_result.failure?

      response = installation_request(
        :get,
        "/repositories/#{escape(repository_id)}/branches",
        query: { per_page: limit, page: (offset / limit) + 1 }
      )
      return response if response.is_a?(Result)

      items = Array(response.body).map do |item|
        Types::Branch.new(
          name: item.fetch("name"),
          sha: item.fetch("commit").fetch("sha"),
          protected: item["protected"] == true
        )
      end.sort_by(&:name)

      Result.success(
        Types::Page.new(
          items:,
          next_cursor: link_cursor(
            response,
            scope: cursor_scope("branches", repository_id, limit:),
            offset:,
            count: items.length
          )
        )
      )
    rescue KeyError, TypeError
      provider_unavailable
    end

    def commits(repository_id:, ref:, cursor: nil, limit: 30)
      return installation_inactive unless @installation_active.call

      scope = cursor_scope("commits", repository_id, ref, limit:)
      offset = decode_offset(cursor, scope:)
      return invalid_cursor if offset.nil?
      return invalid_request unless valid_limit?(limit) && (offset % limit).zero?
      repository_result = authorized_repository(repository_id)
      return repository_result if repository_result.failure?

      response = installation_request(
        :get,
        "/repositories/#{escape(repository_id)}/commits",
        query: { sha: ref, per_page: limit, page: (offset / limit) + 1 }
      )
      return response if response.is_a?(Result)
      return revision_not_found if response.body.blank?

      items = Array(response.body).map { |item| map_commit(item) }
        .sort_by { |commit| [ -commit.authored_at.to_f, commit.sha ] }

      Result.success(
        Types::Page.new(
          items:,
          next_cursor: link_cursor(response, scope:, offset:, count: items.length)
        )
      )
    rescue KeyError, TypeError, ArgumentError, URI::InvalidURIError
      provider_unavailable
    end

    def clone_credentials(repository_id:, revision:)
      return installation_inactive unless @installation_active.call

      repository_result = authorized_repository(repository_id)
      return repository_result if repository_result.failure?
      repository = repository_result.value

      response = installation_request(
        :get,
        "/repositories/#{escape(repository_id)}/commits/#{escape(revision)}"
      )
      return response if response.is_a?(Result)

      token_result = access_token
      return token_result if token_result.failure?

      Result.success(
        Types::CloneCredentials.new(
          clone_url: repository.fetch("clone_url"),
          username: "x-access-token",
          secret: token_result.value.secret,
          expires_at: token_result.value.expires_at
        )
      )
    rescue KeyError, TypeError, URI::InvalidURIError
      provider_unavailable
    end

    def inspect
      "#<#{self.class.name} installation_id=#{@installation_id.inspect} credentials=[REDACTED]>"
    end

    private

    def authorized_repository(repository_id)
      response = installation_request(:get, "/repositories/#{escape(repository_id)}")
      return response if response.is_a?(Result)

      Result.success(response.body)
    end

    def installation_request(method, path, query: nil)
      token_result = access_token
      return token_result if token_result.failure?

      response = @transport.request(
        method:,
        path:,
        headers: { "Authorization" => "Bearer #{token_result.value.secret}" },
        query:
      )
      unless response.status.between?(200, 299)
        not_found = path.include?("/commits") ? :revision_not_found : :repository_not_found
        return response_failure(response, not_found:)
      end

      response
    rescue Http::TransportError
      provider_unavailable
    end

    def access_token
      if @access_token.expires_at <= @clock.call + 60.seconds
        result = @token_resolver.call
        return result if result.failure?

        @access_token = result.value
      end

      Result.success(@access_token)
    end

    def map_repository(item)
      Types::Repository.new(
        id: item.fetch("id"),
        owner: item.fetch("owner").fetch("login"),
        name: item.fetch("name"),
        full_name: item.fetch("full_name"),
        private: item["private"] == true,
        default_branch: item.fetch("default_branch"),
        web_url: item.fetch("html_url")
      )
    end

    def map_commit(item)
      author = item["author"] || {}
      commit_author = item.fetch("commit").fetch("author")

      Types::Commit.new(
        sha: item.fetch("sha"),
        message: item.fetch("commit").fetch("message"),
        author_id: author["id"].presence || "unknown",
        author_login: author["login"].presence || "unknown",
        authored_at: Time.iso8601(commit_author.fetch("date")),
        web_url: item.fetch("html_url")
      )
    end

    def decode_offset(cursor, scope:)
      cursor.nil? ? 0 : @cursor_codec.decode(cursor, scope:)
    end

    def next_cursor(scope:, offset:, count:, total_count:)
      next_offset = offset + count
      @cursor_codec.encode(scope:, offset: next_offset) if next_offset < total_count
    end

    def link_cursor(response, scope:, offset:, count:)
      return unless response.headers.fetch("link", "").include?('rel="next"')

      @cursor_codec.encode(scope:, offset: offset + count)
    end

    def cursor_scope(operation, *parts, limit:)
      ([ operation, @installation_id ] + parts + [ "limit=#{limit}" ]).join(":")
    end

    def valid_limit?(limit)
      limit.is_a?(Integer) && limit.between?(1, MAX_PAGE_SIZE)
    end

    def response_failure(response, not_found:)
      case response.status
      when 401
        failure(:invalid_credentials, "Provider credentials are invalid")
      when 403
        retry_after = response.headers["retry-after"]&.to_i
        if retry_after
          failure(:rate_limited, "Provider rate limit was exceeded", retryable: true, retry_after:)
        else
          failure(:provider_forbidden, "Provider access was denied")
        end
      when 404
        not_found == :revision_not_found ? revision_not_found : repository_not_found
      else
        provider_unavailable
      end
    end

    def invalid_cursor
      failure(:invalid_cursor, "Pagination cursor is invalid")
    end

    def installation_inactive
      failure(:installation_inactive, "Installation is not active")
    end

    def invalid_request
      failure(:invalid_request, "Provider request is invalid")
    end

    def repository_not_found
      failure(:repository_not_found, "Repository was not found")
    end

    def revision_not_found
      failure(:revision_not_found, "Revision was not found")
    end

    def provider_unavailable
      failure(:provider_unavailable, "Provider is unavailable", retryable: true)
    end

    def failure(code, message, retryable: false, retry_after: nil)
      Result.failure(code, message:, retryable:, retry_after:)
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end
  end
end
