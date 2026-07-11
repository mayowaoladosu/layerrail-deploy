module GitProviders
  class Session
    def repositories(cursor: nil, limit: 30)
      raise NotImplementedError
    end

    def branches(repository_id:, cursor: nil, limit: 30)
      raise NotImplementedError
    end

    def commits(repository_id:, ref:, cursor: nil, limit: 30)
      raise NotImplementedError
    end

    def clone_credentials(repository_id:, revision:)
      raise NotImplementedError
    end
  end
end
