require "rails_helper"

RSpec.describe "UUIDv7 identifiers" do
  it "does not allow PostgreSQL to generate a different UUID version" do
    default_functions = [ User, Organization, Membership ].to_h do |model|
      [ model.name, model.columns_hash.fetch("id").default_function ]
    end

    expect(default_functions).to eq(
      "User" => nil,
      "Organization" => nil,
      "Membership" => nil
    )
  end
end
