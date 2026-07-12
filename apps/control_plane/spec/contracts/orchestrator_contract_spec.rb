require "rails_helper"

require "json"
require "json_schemer"

RSpec.describe "Orchestrator contracts" do
  let(:repository_root) { Rails.root.join("../..").expand_path }
  let(:contracts_root) { Pathname(ENV.fetch("LRAIL_CONTRACTS_DIR", repository_root.join("contracts"))) }
  let(:schema_path) { contracts_root.join("orchestrator/v1/workflow-message.schema.json") }
  let(:example_paths) { contracts_root.join("orchestrator/v1/examples").glob("*.json").sort }

  it "accepts only bounded primitive versioned workflow messages" do
    schema = JSON.parse(schema_path.read)
    schemer = JSONSchemer.schema(schema)

    expect(JSONSchemer.valid_schema?(schema)).to be(true)
    expect(example_paths).not_to be_empty
    example_paths.each do |path|
      value = JSON.parse(path.read)
      serialized = JSON.generate(value)

      expect(schemer).to be_valid(value), path.to_s
      expect(serialized.bytesize).to be <= 64.kilobytes
      expect(serialized).not_to match(%r{https?://|password|secret|private_key|token})
    end
  end

  it "rejects unexpected fields, mutable references and contradictory operation results" do
    schemer = JSONSchemer.schema(JSON.parse(schema_path.read))
    input = JSON.parse(example_paths.find { |path| path.basename.to_s == "deployment-input.json" }.read)
    result = JSON.parse(example_paths.find { |path| path.basename.to_s == "operation-result.json" }.read)

    input["source_url"] = "https://credential@example.invalid/repository.git"
    input["source_digest"] = "latest"
    result["stale"] = true

    expect(schemer).not_to be_valid(input)
    expect(schemer).not_to be_valid(result)
  end
end
