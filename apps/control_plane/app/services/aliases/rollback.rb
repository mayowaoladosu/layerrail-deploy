module Aliases
  class Rollback
    class PreviousRevisionMissing < StandardError; end
    class RevisionMismatch < StandardError; end
    class StaleAlias < StandardError; end

    def self.call(context:, alias_record:, revision:, expected_lock_version:)
      unless AliasPolicy.new(context, alias_record).promote?
        raise Pundit::NotAuthorizedError, "not allowed to roll back this alias"
      end

      ApplicationRecord.transaction(requires_new: true) do
        alias_record.lock!
        raise StaleAlias unless alias_record.lock_version == expected_lock_version

        previous = alias_record.previous_revision
        raise PreviousRevisionMissing unless previous
        raise RevisionMismatch unless previous.id == revision.id

        Promote.call(
          context:,
          revision:,
          alias_type: alias_record.alias_type,
          name: alias_record.name
        )
      end
    end
  end
end
