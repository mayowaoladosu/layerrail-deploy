module Environments
  class Create
    Result = Data.define(:environment)

    def self.call(context:, project:, name:, slug: nil, branch: nil)
      new(context:, project:, name:, slug:, branch:).call
    end

    def initialize(context:, project:, name:, slug:, branch:)
      @context = context
      @attributes = {
        project:,
        name:,
        slug:,
        branch:,
        kind: :custom
      }
    end

    def call
      environment = Environment.new(@attributes)
      authorize!(environment)
      environment.save!

      Result.new(environment:)
    end

    private

    def authorize!(environment)
      return if EnvironmentPolicy.new(@context, environment).create?

      raise Pundit::NotAuthorizedError, "not allowed to create this environment"
    end
  end
end
