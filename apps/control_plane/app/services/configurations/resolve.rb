module Configurations
  class Resolve
    Result = Data.define(:snapshot)

    def self.call(context:, project:, environment:, service:)
      new(context:, project:, environment:, service:).call
    end

    def initialize(context:, project:, environment:, service:)
      @context = context
      @project = project
      @environment = environment
      @service = service
    end

    def call
      project_version = latest("project")
      service_version = latest("service:#{@service.id}")
      variables = reveal(project_version).merge(reveal(service_version))
      canonical_payload = JSON.generate(variables.sort.to_h)
      summary = variables.sort.map do |key, entry|
        { "key" => key, "secret" => entry.fetch("secret") }
      end
      snapshot = ConfigurationSnapshot.build_encrypted(
        {
          organization: @context&.organization,
          project: @project,
          environment: @environment,
          service: @service,
          project_configuration_version: project_version,
          service_configuration_version: service_version,
          created_by: @context&.principal,
          key_summary: summary,
          payload_digest: Digest::SHA256.hexdigest(canonical_payload)
        },
        payload_json: canonical_payload
      )
      authorize!(snapshot)
      snapshot.save!

      Result.new(snapshot:)
    end

    private

    def latest(scope_key)
      ConfigurationVersion
        .where(environment: @environment, scope_key:)
        .order(version: :desc)
        .first
    end

    def reveal(version)
      version ? version.send(:decrypted_variables) : {}
    end

    def authorize!(snapshot)
      return if ConfigurationSnapshotPolicy.new(@context, snapshot).create?

      raise Pundit::NotAuthorizedError, "not allowed to resolve this configuration snapshot"
    end
  end
end
