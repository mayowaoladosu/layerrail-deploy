require "rails_helper"

RSpec.describe "Git connection concurrency" do
  self.use_transactional_tests = false

  after do
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

  def run_concurrently(&block)
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          block.call
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.map(&:value)
  end

  def setup_context(sequence)
    owner = User.create!(email: "git-concurrency-#{sequence}@example.com", name: "Concurrency")
    organization = Organizations::Create.call(principal: owner, name: "Git Concurrency #{sequence}").organization
    [ AuthorizationContext.build(principal: owner, organization:), organization ]
  end

  it "returns one installation for concurrent callback retries" do
    context, organization = setup_context(1)
    provider = build_fake_git_provider

    results = run_concurrently do
      GitInstallations::Connect.call(
        context:,
        provider:,
        provider_name: :github,
        provider_installation_id: "installation-1"
      )
    end

    expect(results).to all(be_success)
    expect(results.map { |result| result.value.id }.uniq.length).to eq(1)
    expect(GitInstallation.where(organization:).count).to eq(1)
  end

  it "returns one repository connection for concurrent selection retries" do
    context, organization = setup_context(2)
    provider = build_fake_git_provider
    installation = GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value
    project = Projects::Create.call(context:, name: "Concurrent Project", slug: "concurrent-project").project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "pending"
    ).service

    results = run_concurrently do
      RepositoryConnections::Connect.call(
        context:,
        provider:,
        installation:,
        service:,
        provider_repository_id: "repository-1"
      )
    end

    expect(results).to all(be_success)
    expect(results.map { |result| result.value.id }.uniq.length).to eq(1)
    expect(RepositoryConnection.where(organization:).count).to eq(1)
  end
end
