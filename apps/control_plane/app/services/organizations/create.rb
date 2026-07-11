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
        organization = Organization.create!(name: @name)
        membership = organization.memberships.create!(user: @principal, role: :owner)

        Result.new(organization:, membership:)
      end
    end
  end
end
