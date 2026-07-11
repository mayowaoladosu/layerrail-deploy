require "rails_helper"

RSpec.describe "Project and environment constraints" do
  def create_project(sequence)
    owner = User.create!(email: "project-constraint-#{sequence}@example.com", name: "Owner #{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Organization #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    Projects::Create.call(context:, name: "Project #{sequence}", slug: "project-#{sequence}").project
  end

  it "enforces project name and slug uniqueness within an organization" do
    project = create_project(1)
    context = AuthorizationContext.build(
      principal: project.organization.users.first,
      organization: project.organization
    )

    expect do
      Projects::Create.call(context:, name: project.name.downcase, slug: "different")
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect do
      Projects::Create.call(context:, name: "Different", slug: project.slug)
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "allows the same project name and slug in another organization" do
    first = create_project(2)
    owner = User.create!(email: "other-project-owner@example.com", name: "Other")
    organization = Organizations::Create.call(principal: owner, name: "Other Organization").organization
    context = AuthorizationContext.build(principal: owner, organization:)

    second = Projects::Create.call(context:, name: first.name, slug: first.slug).project

    expect(second).to be_persisted
    expect(second.organization).to eq(organization)
  end

  it "enforces canonical environment and branch uniqueness per project" do
    project = create_project(3)
    production = project.environments.find_by!(kind: :production)
    staging = project.environments.find_by!(kind: :staging)
    production.update!(branch: "main")

    expect(project.environments.new(name: "Production 2", slug: "production-2", kind: :production)).not_to be_valid
    expect(project.environments.new(name: "Staging 2", slug: "staging-2", kind: :staging)).not_to be_valid
    expect(project.environments.new(name: "Preview", slug: "preview", kind: :custom, branch: "main")).not_to be_valid
    expect(staging.update(branch: "develop")).to be(true)
  end

  it "stores project and environment UUIDs without database-generated defaults" do
    default_functions = [ Project, Environment ].to_h do |model|
      [ model.name, model.columns_hash.fetch("id").default_function ]
    end

    expect(default_functions).to eq("Project" => nil, "Environment" => nil)
  end
end
