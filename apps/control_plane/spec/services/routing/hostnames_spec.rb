require "rails_helper"

RSpec.describe Routing::Hostnames do
  def alias_target(id:, project_slug: "shared-project", service_name: "Web", environment_slug: "production")
    Data.define(:id, :project, :service, :environment).new(
      id:,
      project: Data.define(:slug).new(slug: project_slug),
      service: Data.define(:name).new(name: service_name),
      environment: Data.define(:slug).new(slug: environment_slug)
    )
  end

  it "makes identical human-readable aliases globally unique" do
    first = alias_target(id: "019f5406-1000-7000-8000-000000000001")
    second = alias_target(id: "019f5406-1000-7000-8000-000000000002")

    first_hostname = described_class.environment(first)
    second_hostname = described_class.environment(second)

    expect(first_hostname).not_to eq(second_hostname)
    expect(first_hostname).to end_with("019f5406100070008000000000000001.localhost")
    expect(second_hostname).to end_with("019f5406100070008000000000000002.localhost")
  end

  it "keeps the DNS label bounded without truncating its identity" do
    target = alias_target(
      id: "019f5406-1000-7000-8000-000000000003",
      project_slug: "project-#{"x" * 80}",
      service_name: "Service #{"y" * 80}",
      environment_slug: "environment-#{"z" * 80}"
    )

    label = described_class.environment(target, domain: "deploy.example.com").split(".").first

    expect(label.bytesize).to eq(63)
    expect(label).to end_with("-019f5406100070008000000000000003")
  end
end
