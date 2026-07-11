module Services
  class Create
    Result = Data.define(:service)

    def self.call(
      context:,
      project:,
      name:,
      workload_type:,
      source_type:,
      source_reference:,
      runtime_policy: {}
    )
      new(
        context:,
        project:,
        name:,
        workload_type:,
        source_type:,
        source_reference:,
        runtime_policy:
      ).call
    end

    def initialize(context:, project:, name:, workload_type:, source_type:, source_reference:, runtime_policy:)
      @context = context
      @attributes = {
        project:,
        name:,
        workload_type:,
        source_type:,
        source_reference:,
        runtime_policy:
      }
    end

    def call
      service = Service.new(@attributes)
      authorize!(service)
      service.save!

      Result.new(service:)
    end

    private

    def authorize!(service)
      return if ServicePolicy.new(@context, service).create?

      raise Pundit::NotAuthorizedError, "not allowed to create this service"
    end
  end
end
