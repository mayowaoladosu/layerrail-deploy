require "uri"

module GitProviders
  module Types
    module_function

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, child| [ key.to_s.freeze, deep_freeze(child) ] }.freeze
      when Array
        value.map { |child| deep_freeze(child) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end

    InstallationSetup = Data.define(:url, :state) do
      def initialize(url:, state:)
        super(url: URI(url.to_s).freeze, state: state.to_s.dup.freeze)
      end
    end

    Installation = Data.define(
      :id,
      :account_id,
      :account_login,
      :account_type,
      :status,
      :permissions
    ) do
      def initialize(id:, account_id:, account_login:, account_type:, status:, permissions:)
        super(
          id: id.to_s.dup.freeze,
          account_id: account_id.to_s.dup.freeze,
          account_login: account_login.to_s.dup.freeze,
          account_type: account_type.to_s.dup.freeze,
          status: status.to_s.dup.freeze,
          permissions: GitProviders::Types.deep_freeze(permissions)
        )
      end
    end

    Repository = Data.define(
      :id,
      :owner,
      :name,
      :full_name,
      :private,
      :default_branch,
      :web_url
    ) do
      def initialize(id:, owner:, name:, full_name:, private:, default_branch:, web_url:)
        super(
          id: id.to_s.dup.freeze,
          owner: owner.to_s.dup.freeze,
          name: name.to_s.dup.freeze,
          full_name: full_name.to_s.dup.freeze,
          private: !!private,
          default_branch: default_branch.to_s.dup.freeze,
          web_url: URI(web_url.to_s).freeze
        )
      end
    end

    Branch = Data.define(:name, :sha, :protected) do
      def initialize(name:, sha:, protected:)
        super(
          name: name.to_s.dup.freeze,
          sha: sha.to_s.dup.freeze,
          protected: !!protected
        )
      end
    end

    Commit = Data.define(
      :sha,
      :message,
      :author_id,
      :author_login,
      :authored_at,
      :web_url
    ) do
      def initialize(sha:, message:, author_id:, author_login:, authored_at:, web_url:)
        super(
          sha: sha.to_s.dup.freeze,
          message: message.to_s.dup.freeze,
          author_id: author_id.to_s.dup.freeze,
          author_login: author_login.to_s.dup.freeze,
          authored_at: authored_at,
          web_url: URI(web_url.to_s).freeze
        )
      end
    end

    ProviderUser = Data.define(:id, :login, :name, :email) do
      def initialize(id:, login:, name:, email:)
        super(
          id: id.to_s.dup.freeze,
          login: login.to_s.dup.freeze,
          name: name.to_s.dup.freeze,
          email: email.to_s.dup.freeze
        )
      end
    end

    Page = Data.define(:items, :next_cursor) do
      def initialize(items:, next_cursor:)
        super(
          items: items.dup.freeze,
          next_cursor: next_cursor&.to_s&.dup&.freeze
        )
      end
    end

    WebhookEvent = Data.define(
      :delivery_id,
      :type,
      :installation_id,
      :repository_id,
      :occurred_at,
      :data
    ) do
      def initialize(delivery_id:, type:, installation_id:, repository_id:, occurred_at:, data:)
        super(
          delivery_id: delivery_id.to_s.dup.freeze,
          type: type.to_s.dup.freeze,
          installation_id: installation_id&.to_s&.dup&.freeze,
          repository_id: repository_id&.to_s&.dup&.freeze,
          occurred_at:,
          data: GitProviders::Types.deep_freeze(data)
        )
      end
    end

    class CloneCredentials
      attr_reader :clone_url, :username, :expires_at

      def initialize(clone_url:, username:, secret:, expires_at:)
        @clone_url = URI(clone_url.to_s).freeze
        @username = username.to_s.dup.freeze
        @secret = secret.to_s.dup.freeze
        @expires_at = expires_at
        freeze
      end

      def secret
        @secret
      end

      def to_h
        {
          clone_url:,
          username:,
          expires_at:
        }
      end

      def inspect
        "#<#{self.class.name} clone_url=#{clone_url} username=#{username.inspect} secret=[REDACTED] expires_at=#{expires_at.iso8601}>"
      end
    end
  end
end
