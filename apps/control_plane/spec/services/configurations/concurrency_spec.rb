require "rails_helper"

RSpec.describe "Configuration snapshot concurrency" do
  self.use_transactional_tests = false

  after do
    ConfigurationVersion.delete_all
    GitWebhookInbox.delete_all
    RepositoryConnection.delete_all
    GitInstallation.delete_all
    Service.delete_all
    Environment.delete_all
    Project.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  it "assigns one monotonic version per concurrent scope write" do
    owner = User.create!(email: "config-concurrency@example.com", name: "Config")
    organization = Organizations::Create.call(principal: owner, name: "Config Concurrency").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    project = Projects::Create.call(context:, name: "Concurrent Config", slug: "concurrent-config").project
    environment = project.environments.find_by!(kind: :production)
    ready = Queue.new
    release = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          Configurations::Snapshot.call(
            context:,
            project:,
            environment:,
            variables: { "VALUE" => index.to_s }
          ).version
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    versions = threads.map(&:value)

    expect(versions.map(&:version).sort).to eq([ 1, 2 ])
    expect(ConfigurationVersion.where(environment:, scope_key: "project").count).to eq(2)
  end
end
