require "rails_helper"

require "json"
require "json_schemer"

RSpec.describe "Build controller contract" do
  let(:repository_root) { Rails.root.join("../..").expand_path }
  let(:contracts_root) { Pathname(ENV.fetch("LRAIL_CONTRACTS_DIR", repository_root.join("contracts"))) }
  let(:schema_path) { contracts_root.join("provider/v1/build-controller.schema.json") }
  let(:examples) { contracts_root.join("provider/v1/examples").glob("build-*.json").sort }

  it "accepts every bounded build command, credential, result and cancellation example" do
    schema = JSON.parse(schema_path.read)
    schemer = JSONSchemer.schema(schema)

    expect(JSONSchemer.valid_schema?(schema)).to be(true)
    expect(examples.map { |path| path.basename.to_s }).to contain_exactly(
      "build-cancel-command.json",
      "build-clone-credentials.json",
      "build-command.json",
      "build-worker-result.json"
    )
    examples.each do |path|
      value = JSON.parse(path.read)

      expect(schemer).to be_valid(value), path.to_s
      expect(JSON.generate(value).bytesize).to be <= 48.megabytes
    end
  end

  it "rejects cross-tenant repositories, mutable artifact identities and extra secrets" do
    schemer = JSONSchemer.schema(JSON.parse(schema_path.read))
    command = JSON.parse(contracts_root.join("provider/v1/examples/build-command.json").read)
    traversal = command.deep_dup
    result = JSON.parse(contracts_root.join("provider/v1/examples/build-worker-result.json").read)
    credentials = JSON.parse(contracts_root.join("provider/v1/examples/build-clone-credentials.json").read)

    command["repository"] = "foreign/repository"
    traversal["source_root"] = "../secret"
    result["artifact_digest"] = "latest"
    credentials["refresh_token"] = "must-not-cross-boundary"

    expect(schemer).not_to be_valid(command)
    expect(schemer).not_to be_valid(traversal)
    expect(schemer).not_to be_valid(result)
    expect(schemer).not_to be_valid(credentials)
  end
end
