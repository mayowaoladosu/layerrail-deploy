require "rails_helper"

RSpec.describe "Idempotency concurrency" do
  self.use_transactional_tests = false

  after do
    IdempotencyRecord.delete_all
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end

  it "executes one logical side effect for concurrent requests with the same key" do
    owner = User.create!(email: "idempotency-concurrency@example.com", name: "Concurrency")
    organization = Organizations::Create.call(principal: owner, name: "Concurrency").organization
    ready = Queue.new
    release = Queue.new
    execution_mutex = Mutex.new
    executions = 0

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop

          Api::Idempotency::Execute.call(
            organization:,
            key: "concurrent-operation",
            operation: "testOperation",
            payload: { "name" => "same" }
          ) do
            execution_mutex.synchronize { executions += 1 }
            { status: :created, body: { "result" => "created" } }
          end
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)

    expect(executions).to eq(1)
    expect(results.map(&:body).uniq).to eq([ { "result" => "created" } ])
    expect(results.count(&:replayed)).to eq(1)
    expect(IdempotencyRecord.where(organization:, key: "concurrent-operation").count).to eq(1)
  end
end
