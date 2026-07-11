require "rails_helper"

RSpec.describe "Project resource policies" do
  def create_user(sequence)
    User.create!(email: "project-policy-#{sequence}@example.com", name: "User #{sequence}")
  end

  def create_project_domain(sequence)
    owner = create_user("owner-#{sequence}")
    organization = Organizations::Create.call(principal: owner, name: "Policy Organization #{sequence}").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Policy Project #{sequence}", slug: "policy-project-#{sequence}").project
    service = Services::Create.call(
      context:,
      project:,
      name: "Web",
      workload_type: :web,
      source_type: :git,
      source_reference: "github:layerrail/policy-#{sequence}"
    ).service

    [ owner, organization, context, project, service ]
  end

  it "applies owner, admin, and member permissions to a project" do
    owner, organization, owner_context, project, = create_project_domain(1)
    admin = create_user("admin-1")
    member = create_user("member-1")
    organization.memberships.create!(user: admin, role: :admin)
    organization.memberships.create!(user: member, role: :member)
    admin_policy = ProjectPolicy.new(AuthorizationContext.build(principal: admin, organization:), project)
    member_policy = ProjectPolicy.new(AuthorizationContext.build(principal: member, organization:), project)
    owner_policy = ProjectPolicy.new(owner_context, project)

    expect(owner_policy).to be_show
    expect(owner_policy).to be_update
    expect(owner_policy).to be_request_deletion
    expect(admin_policy).to be_show
    expect(admin_policy).to be_update
    expect(admin_policy).not_to be_request_deletion
    expect(member_policy).to be_show
    expect(member_policy).not_to be_update
    expect(member_policy).not_to be_request_deletion
    expect(owner).to be_persisted
  end

  it "scopes projects, services, and environments to the selected organization" do
    owner, organization, context, project, service = create_project_domain(2)
    _foreign_owner, _foreign_organization, _foreign_context, foreign_project, foreign_service = create_project_domain(3)
    environment = project.environments.find_by!(kind: :production)
    foreign_environment = foreign_project.environments.find_by!(kind: :production)

    expect(ProjectPolicy::Scope.new(context, Project.all).resolve).to contain_exactly(project)
    expect(ServicePolicy::Scope.new(context, Service.all).resolve).to contain_exactly(service)
    expect(EnvironmentPolicy::Scope.new(context, Environment.all).resolve).to contain_exactly(*project.environments)
    expect(ServicePolicy.new(context, foreign_service)).not_to be_show
    expect(EnvironmentPolicy.new(context, foreign_environment)).not_to be_show
    expect(owner.organizations).to contain_exactly(organization)
    expect(environment).to be_persisted
  end

  it "reserves canonical environment deletion for project deletion" do
    _owner, _organization, context, project, = create_project_domain(4)
    production = project.environments.find_by!(kind: :production)
    staging = project.environments.find_by!(kind: :staging)
    custom = Environments::Create.call(context:, project:, name: "QA", slug: "qa").environment

    expect(EnvironmentPolicy.new(context, production)).not_to be_request_deletion
    expect(EnvironmentPolicy.new(context, staging)).not_to be_request_deletion
    expect(EnvironmentPolicy.new(context, custom)).to be_request_deletion
  end
end
