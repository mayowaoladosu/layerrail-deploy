require "rails_helper"

RSpec.describe "Service constraints" do
  def create_project(sequence)
    owner = User.create!(email: "service-constraint-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Service Organization #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Service Project #{sequence}", slug: "service-project-#{sequence}").project

    [ context, project ]
  end

  def create_service(context, project, name: "API")
    Services::Create.call(
      context:,
      project:,
      name:,
      workload_type: :web,
      source_type: :git,
      source_reference: "github:layerrail/#{name.parameterize}",
      runtime_policy: {}
    ).service
  end

  it "enforces service name uniqueness within a project" do
    context, project = create_project(1)
    create_service(context, project)

    expect do
      create_service(context, project, name: "api")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "allows the same service name in another project" do
    first_context, first_project = create_project(2)
    second_context, second_project = create_project(3)
    first = create_service(first_context, first_project)
    second = create_service(second_context, second_project)

    expect(first.name).to eq(second.name)
    expect(first.organization).not_to eq(second.organization)
  end

  it "rejects unsupported workload and source types" do
    _context, project = create_project(4)
    service = Service.new(
      project:,
      name: "Invalid",
      workload_type: "database",
      source_type: "archive",
      source_reference: "source"
    )

    expect(service).not_to be_valid
    expect(service.errors).to be_of_kind(:workload_type, :inclusion)
    expect(service.errors).to be_of_kind(:source_type, :inclusion)
  end

  it "rejects unknown or unsafe runtime policy settings" do
    _context, project = create_project(5)

    unknown = Service.new(
      project:,
      name: "Unknown policy",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:layerrail/unknown",
      runtime_policy: { "privileged" => true }
    )
    unsafe_path = Service.new(
      project:,
      name: "Unsafe path",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:layerrail/path",
      runtime_policy: { "readiness_path" => "health" }
    )

    expect(unknown).not_to be_valid
    expect(unsafe_path).not_to be_valid
  end

  it "stores Service UUIDs without a database-generated default" do
    expect(Service.columns_hash.fetch("id").default_function).to be_nil
  end
end
