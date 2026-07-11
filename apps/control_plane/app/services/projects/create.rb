module Projects
  class Create
    Result = Data.define(:project, :production_environment, :staging_environment)

    def self.call(context:, name:, slug: nil)
      new(context:, name:, slug:).call
    end

    def initialize(context:, name:, slug:)
      @context = context
      @name = name
      @slug = slug
    end

    def call
      ApplicationRecord.transaction do
        project = Project.new(
          organization: @context&.organization,
          name: @name,
          slug: @slug
        )
        authorize!(project)
        project.save!

        production_environment = project.environments.create!(
          name: "Production",
          slug: "production",
          kind: :production
        )
        staging_environment = project.environments.create!(
          name: "Staging",
          slug: "staging",
          kind: :staging
        )

        Result.new(project:, production_environment:, staging_environment:)
      end
    end

    private

    def authorize!(project)
      return if ProjectPolicy.new(@context, project).create?

      raise Pundit::NotAuthorizedError, "not allowed to create this project"
    end
  end
end
