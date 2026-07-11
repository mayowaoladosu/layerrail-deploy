module Configurations
  class Reveal
    Result = Data.define(:variables)

    def self.call(context:, version:)
      unless ConfigurationVersionPolicy.new(context, version).reveal?
        raise Pundit::NotAuthorizedError, "not allowed to reveal this configuration version"
      end

      variables = version.send(:decrypted_variables)
      Result.new(variables: GitProviders::Types.deep_freeze(variables))
    end
  end
end
