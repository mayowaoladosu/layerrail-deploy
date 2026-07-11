module Configurations
  class RevealSnapshot
    Result = Data.define(:variables)

    def self.call(context:, snapshot:)
      unless ConfigurationSnapshotPolicy.new(context, snapshot).reveal?
        raise Pundit::NotAuthorizedError, "not allowed to reveal this configuration snapshot"
      end

      variables = snapshot.send(:decrypted_variables)
      Result.new(variables: GitProviders::Types.deep_freeze(variables))
    end
  end
end
