require "rails_helper"

RSpec.describe Api::Idempotency::Execute do
  def create_context(sequence)
    owner = User.create!(email: "idempotency-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Idempotency #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)

    [ organization, context ]
  end

  it "rolls back domain state and the record when execution fails" do
    organization, context = create_context(1)
    project_count = Project.count
    environment_count = Environment.count

    expect do
      described_class.call(
        organization:,
        key: "failed-operation",
        operation: "createProject",
        payload: { "name" => "Transient" }
      ) do
        Projects::Create.call(context:, name: "Transient", slug: "transient")
        raise "provider failed"
      end
    end.to raise_error(RuntimeError, "provider failed")

    expect(Project.count).to eq(project_count)
    expect(Environment.count).to eq(environment_count)
    expect(IdempotencyRecord.where(organization:, key: "failed-operation")).not_to exist
  end

  it "canonicalizes request object key order before replay" do
    organization, = create_context(2)
    executions = 0

    first = described_class.call(
      organization:,
      key: "canonical-request",
      operation: "testOperation",
      payload: { "second" => 2, "first" => { "nested" => true } }
    ) do
      executions += 1
      { status: :created, body: { "result" => "created" } }
    end
    second = described_class.call(
      organization:,
      key: "canonical-request",
      operation: "testOperation",
      payload: { "first" => { "nested" => true }, "second" => 2 }
    ) do
      executions += 1
      { status: :created, body: { "result" => "duplicate" } }
    end

    expect(first.replayed).to be(false)
    expect(second.replayed).to be(true)
    expect(second.body).to eq("result" => "created")
    expect(executions).to eq(1)
  end

  it "scopes the same key to separate organizations" do
    first_organization, = create_context(3)
    second_organization, = create_context(4)

    [ first_organization, second_organization ].each do |organization|
      described_class.call(
        organization:,
        key: "shared-key",
        operation: "testOperation",
        payload: { "organization_id" => organization.id }
      ) do
        { status: :created, body: { "organization_id" => organization.id } }
      end
    end

    expect(IdempotencyRecord.where(key: "shared-key").count).to eq(2)
  end

  it "stores an application-generated UUIDv7 without a database default" do
    organization, = create_context(5)

    described_class.call(
      organization:,
      key: "uuid-record",
      operation: "testOperation",
      payload: {}
    ) do
      { status: :created, body: {} }
    end
    record = IdempotencyRecord.find_by!(organization:, key: "uuid-record")

    expect(record.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
    expect(IdempotencyRecord.columns_hash.fetch("id").default_function).to be_nil
  end
end
