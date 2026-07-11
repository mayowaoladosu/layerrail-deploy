module Configurations
  class Snapshot
    class InvalidVariables < StandardError; end

    Result = Data.define(:version)
    MAX_VARIABLES = 256
    MAX_VALUE_BYTES = 32.kilobytes
    MAX_PAYLOAD_BYTES = 256.kilobytes
    KEY_PATTERN = /\A[A-Z_][A-Z0-9_]{0,127}\z/

    def self.call(context:, project:, environment:, variables:, service: nil)
      new(context:, project:, environment:, variables:, service:).call
    end

    def initialize(context:, project:, environment:, variables:, service:)
      @context = context
      @project = project
      @environment = environment
      @service = service
      @variables = normalize(variables)
    end

    def call
      scope_key = @service ? "service:#{@service.id}" : "project"
      candidate = ConfigurationVersion.new(
        organization: @context&.organization,
        project: @project,
        environment: @environment,
        service: @service,
        created_by: @context&.principal,
        scope_key:,
        version: 1,
        key_summary: summary,
        payload_digest: digest
      )
      authorize!(candidate)

      ApplicationRecord.transaction(requires_new: true) do
        lock_scope!(scope_key)
        version_number = ConfigurationVersion
          .where(environment: @environment, scope_key:)
          .maximum(:version).to_i + 1
        version = ConfigurationVersion.build_encrypted(
          {
            organization: @context.organization,
            project: @project,
            environment: @environment,
            service: @service,
            created_by: @context.principal,
            scope_key:,
            version: version_number,
            key_summary: summary,
            payload_digest: digest
          },
          payload_json: canonical_payload
        )
        version.save!

        Result.new(version:)
      end
    end

    private

    def normalize(variables)
      raise InvalidVariables unless variables.is_a?(Hash) && variables.length <= MAX_VARIABLES

      normalized = {}
      variables.each do |raw_key, raw_entry|
        key = raw_key.to_s.strip
        raise InvalidVariables unless KEY_PATTERN.match?(key)
        raise InvalidVariables if normalized.key?(key)

        entry = normalize_entry(raw_entry)
        raise InvalidVariables if entry.fetch("value").bytesize > MAX_VALUE_BYTES

        normalized[key] = entry
      end
      normalized = normalized.sort.to_h
      payload = JSON.generate(normalized)
      raise InvalidVariables if payload.bytesize > MAX_PAYLOAD_BYTES

      normalized.freeze
    end

    def normalize_entry(entry)
      return { "value" => entry.dup.freeze, "secret" => false }.freeze if entry.is_a?(String)
      raise InvalidVariables unless entry.is_a?(Hash)

      value = entry[:value] || entry["value"]
      secret = entry.key?(:secret) ? entry[:secret] : entry["secret"]
      raise InvalidVariables unless value.is_a?(String) && [ true, false, nil ].include?(secret)
      allowed_keys = entry.keys.map(&:to_s)
      raise InvalidVariables unless (allowed_keys - %w[value secret]).empty?

      { "value" => value.dup.freeze, "secret" => secret == true }.freeze
    end

    def canonical_payload
      @canonical_payload ||= JSON.generate(@variables)
    end

    def digest
      Digest::SHA256.hexdigest(canonical_payload)
    end

    def summary
      @variables.map do |key, entry|
        { "key" => key, "secret" => entry.fetch("secret") }
      end
    end

    def authorize!(candidate)
      return if ConfigurationVersionPolicy.new(@context, candidate).create?

      raise Pundit::NotAuthorizedError, "not allowed to create this configuration version"
    end

    def lock_scope!(scope_key)
      key = "#{@environment.id}:#{scope_key}"
      quoted_key = ApplicationRecord.connection.quote(key)
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))"
      )
    end
  end
end
