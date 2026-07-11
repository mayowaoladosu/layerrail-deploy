require "rails_helper"

require "json"
require "json_schemer"
require "openapi3_parser"
require "yaml"

RSpec.describe "Versioned contracts" do
  let(:repository_root) { Rails.root.join("../..").expand_path }
  let(:contracts_root) { Pathname(ENV.fetch("LRAIL_CONTRACTS_DIR", repository_root.join("contracts"))) }
  let(:openapi_path) { contracts_root.join("openapi/v1/openapi.yaml") }
  let(:event_schema_path) { contracts_root.join("events/v1/event-envelope.schema.json") }
  let(:event_example_paths) { contracts_root.join("events/v1/examples").glob("*.json").sort }

  describe "the public REST API" do
    let(:required_operations) do
      {
        "/organizations" => { "post" => "createOrganization" },
        "/organizations/{organization_id}/projects" => { "get" => "listOrganizationProjects" },
        "/projects" => { "post" => "createProject" },
        "/projects/{project_id}/services" => { "post" => "createProjectService" },
        "/services/{service_id}/deployments" => { "post" => "createDeployment" },
        "/deployments/{deployment_id}" => { "get" => "getDeployment" },
        "/deployments/{deployment_id}/cancel" => { "post" => "cancelDeployment" },
        "/environments/{environment_id}/promotions" => { "post" => "promoteEnvironment" },
        "/environments/{environment_id}/rollbacks" => { "post" => "rollbackEnvironment" },
        "/deployments/{deployment_id}/logs" => { "get" => "listDeploymentLogs" },
        "/services/{service_id}/domains" => { "post" => "createServiceDomain" },
        "/services/{service_id}/scale" => { "post" => "scaleService" }
      }
    end

    it "is a valid OpenAPI document" do
      document = Openapi3Parser.load_file(openapi_path)

      expect(document).to be_valid, document.errors.to_s
    end

    it "preserves the minimum v1 operation surface" do
      contract = YAML.safe_load_file(openapi_path, aliases: true)

      required_operations.each do |path, methods|
        methods.each do |method, operation_id|
          operation = contract.fetch("paths").fetch(path).fetch(method)

          expect(operation.fetch("operationId")).to eq(operation_id)
        end
      end
    end

    it "requires an idempotency key for every mutation" do
      contract = YAML.safe_load_file(openapi_path, aliases: true)

      required_operations.each_key do |path|
        operation = contract.fetch("paths").fetch(path)["post"]
        next unless operation

        references = operation.fetch("parameters").filter_map { |parameter| parameter["$ref"] }

        expect(references).to include("#/components/parameters/IdempotencyKey")
      end
    end

    it "requires every service to have one bounded source and runtime policy" do
      contract = YAML.safe_load_file(openapi_path, aliases: true)
      schemas = contract.fetch("components").fetch("schemas")

      expect(schemas.fetch("Service").fetch("required")).to include("source", "runtime_policy")
      expect(schemas.fetch("CreateServiceRequest").fetch("required")).to include("source")
      expect(schemas.fetch("SourceSnapshot").fetch("additionalProperties")).to be(false)
      expect(schemas.fetch("RuntimePolicy").fetch("additionalProperties")).to be(false)
      expect(schemas.fetch("Environment").fetch("properties").fetch("project_id"))
        .to eq("$ref" => "#/components/schemas/PublicId")
    end
  end

  describe "the canonical event envelope" do
    it "is a valid JSON Schema and accepts every versioned example" do
      schema = JSON.parse(event_schema_path.read)

      expect(JSONSchemer.valid_schema?(schema)).to be(true)
      event_example_paths.each do |path|
        expect(JSONSchemer.schema(schema)).to be_valid(JSON.parse(path.read)), path.to_s
      end
    end

    it "rejects an event without its tenant owner" do
      schema = JSON.parse(event_schema_path.read)
      example = JSON.parse(event_example_paths.first.read).except("organization_id")

      expect(JSONSchemer.schema(schema)).not_to be_valid(example)
    end
  end
end
