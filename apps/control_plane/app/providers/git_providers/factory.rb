module GitProviders
  class Factory
    def self.github(env: ENV)
      e2e_path = env["BUILD_CONTROLLER_E2E_PROVIDER_FILE"]
      if Rails.env.development? && e2e_path.present? && Pathname(e2e_path).file?
        return E2eAdapter.new(path: e2e_path)
      end

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
