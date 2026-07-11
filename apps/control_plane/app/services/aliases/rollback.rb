module Aliases
  class Rollback
    class PreviousRevisionMissing < StandardError; end
    class StaleAlias < StandardError; end

    def self.call(context:, alias_record:, expected_lock_version:)
      ApplicationRecord.transaction(requires_new: true) do
        alias_record.lock!
        raise StaleAlias unless alias_record.lock_version == expected_lock_version

        previous = alias_record.previous_revision
        raise PreviousRevisionMissing unless previous

        Promote.call(
          context:,
          revision: previous,
          alias_type: alias_record.alias_type,
          name: alias_record.name
        )
      end
    end
  end
end
