require "rails_helper"

RSpec.describe "Event delivery concurrency" do
  self.use_transactional_tests = false

  class ConcurrentPublisher
    attr_reader :calls

    def initialize
      @calls = 0
      @mutex = Mutex.new
    end

    def publish(envelope:)
      envelope.fetch("event_id")
      @mutex.synchronize { @calls += 1 }
      OutboxEvents::DeliveryResult.published
    end
  end

  after do
    EventReceipt.delete_all
    OutboxEvent.delete_all
    Alias.delete_all
    Revision.delete_all
    Build.delete_all
    DeploymentTransition.delete_all
    Deployment.delete_all
    ConfigurationSnapshot.delete_all
    ConfigurationVersion.delete_all
    RepositoryConnection.delete_all
    GitWebhookInbox.delete_all
    GitInstallation.delete_all
    Service.delete_all
    Environment.delete_all
    Project.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  def setup_event
    owner = User.create!(email: "event-concurrency@example.com", name: "Event Concurrency")
    organization = Organizations::Create.call(principal: owner, name: "Event Concurrency").organization
    attributes = {
      organization:,
      resource_id: SecureRandom.uuid_v7,
      event_type: "deployment.transitioned.v1",
      correlation_id: SecureRandom.uuid_v7,
      idempotency_key: "event-concurrency-1",
      producer: "control-plane",
      data: { "status" => "queued" }
    }

    [ organization, attributes ]
  end

  it "publishes one event for concurrent retries of the same command" do
    _organization, attributes = setup_event
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          OutboxEvents::Publish.call(**attributes)
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results.count(&:replayed)).to eq(1)
    expect(results.map { |result| result.event.id }.uniq.one?).to be(true)
    expect(OutboxEvent.count).to eq(1)
  end

  it "applies one database side effect for concurrent delivery of one event" do
    organization, attributes = setup_event
    event = OutboxEvents::Publish.call(**attributes).event
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          EventConsumers::Process.call(consumer: "local-provider", envelope: event.envelope) do
            project = Project.create!(organization:, name: "Exactly Once", slug: "exactly-once")
            { "project_id" => project.id }
          end
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results.count(&:replayed)).to eq(1)
    expect(results.map(&:result).uniq.one?).to be(true)
    expect(Project.count).to eq(1)
    expect(EventReceipt.count).to eq(1)
  end

  it "allows one dispatcher to claim a pending event" do
    _organization, attributes = setup_event
    event = OutboxEvents::Publish.call(**attributes).event
    publisher = ConcurrentPublisher.new
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          OutboxEvents::Dispatch.call(publisher:, now: event.available_at, limit: 1)
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(results.sum(&:published)).to eq(1)
    expect(publisher.calls).to eq(1)
    expect(event.reload.status).to eq("published")
  end
end
