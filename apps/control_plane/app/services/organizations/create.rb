module Organizations
  class Create
    Result = Data.define(:organization, :membership)

    def self.call(principal:, name:)
      new(principal:, name:).call
    end

    def initialize(principal:, name:)
      raise ArgumentError, "principal must be a persisted user" unless principal&.persisted?

      @principal = principal
      @name = name
    end

    def call
      ApplicationRecord.transaction do
        id = SecureRandom.uuid_v7
        base_slug = @name.to_s.parameterize.first(64).delete_suffix("-").presence || "team"
        lock_slug!(base_slug)
        slug = if Organization.exists?(slug: base_slug)
          suffix = "-#{id.delete("-").first(8)}"
          "#{base_slug.first(64 - suffix.length).delete_suffix("-")}#{suffix}"
        else
          base_slug
        end
        organization = Organization.create!(id:, name: @name, slug:)
        membership = organization.memberships.create!(user: @principal, role: :owner)

        Result.new(organization:, membership:)
      end
    end

    private

    def lock_slug!(slug)
      quoted_slug = ApplicationRecord.connection.quote("organization-slug:#{slug}")
      ApplicationRecord.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_slug}, 0))"
      )
    end
  end
end
