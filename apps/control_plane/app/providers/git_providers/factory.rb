module GitProviders
  class Factory
    def self.github(env: ENV)
      GithubAdapter.new(
        app_id: env.fetch("GITHUB_APP_ID"),
        app_slug: env.fetch("GITHUB_APP_NAME"),
        private_key: env.fetch("GITHUB_APP_PRIVATE_KEY").gsub("\\n", "\n"),
        webhook_secret: env.fetch("GITHUB_APP_WEBHOOK_SECRET"),
        cursor_secret: env.fetch("SECRET_KEY")
      )
    end
  end
end
