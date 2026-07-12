require "rails_helper"

require "json"
require "json_schemer"

RSpec.describe "Static artifact contract" do
  let(:repository_root) { Rails.root.join("../..").expand_path }
  let(:contracts_root) { Pathname(ENV.fetch("LRAIL_CONTRACTS_DIR", repository_root.join("contracts"))) }
  let(:schema_path) { contracts_root.join("provider/v1/static-artifact-manifest.schema.json") }
  let(:example_path) { contracts_root.join("provider/v1/examples/static-artifact-manifest.json") }
  let(:provider_schema_path) { contracts_root.join("provider/v1/artifact-provider.schema.json") }
  let(:provider_example_paths) { contracts_root.join("provider/v1/examples").glob("artifact-provider-*.json").sort }

  it "publishes a valid bounded manifest example" do
    schema = JSON.parse(schema_path.read)

    expect(JSONSchemer.valid_schema?(schema)).to be(true)
    expect(JSONSchemer.schema(schema)).to be_valid(JSON.parse(example_path.read))
  end

  it "rejects traversal paths and mutable archive identities" do
    schema = JSONSchemer.schema(JSON.parse(schema_path.read))
    example = JSON.parse(example_path.read)

    example.fetch("files").first["path"] = "../secret"
    example.fetch("archive")["digest"] = "latest"

    expect(schema).not_to be_valid(example)
  end

  it "maps local and Google providers without serializing credentials" do
    schema = JSON.parse(provider_schema_path.read)

    expect(JSONSchemer.valid_schema?(schema)).to be(true)
    provider_example_paths.each do |path|
      value = JSON.parse(path.read)

      expect(JSONSchemer.schema(schema)).to be_valid(value), path.to_s
      expect(value.to_json).not_to match(/"(?:password|token|private_key|access_key|secret_key)"\s*:/i)
    end
  end
end
