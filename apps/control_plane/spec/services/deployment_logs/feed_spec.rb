require "rails_helper"

RSpec.describe DeploymentLogs::Feed do
  def provider_result(entries:, status: :ok, truncated: false, retained: false)
    LocalProvider::LogClient::Result.new(status:, entries:, truncated:, retained:)
  end

  def runtime_entry(timestamp:, message:)
    LocalProvider::LogClient::Entry.new(
      timestamp: Time.iso8601(timestamp),
      stream: "runtime",
      message:
    )
  end

  it "tails persisted and runtime entries and advances an opaque cursor" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-feed")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    first_runtime = runtime_entry(timestamp: (Time.current + 1.second).iso8601(6), message: "first runtime line")
    second_runtime = runtime_entry(timestamp: (Time.current + 2.seconds).iso8601(6), message: "second runtime line")

    first = described_class.call(
      deployment:,
      provider_result: provider_result(entries: [ first_runtime, second_runtime ]),
      limit: 2
    )
    third_runtime = runtime_entry(timestamp: (Time.current + 3.seconds).iso8601(6), message: "third runtime line")
    second = described_class.call(
      deployment:,
      provider_result: provider_result(entries: [ first_runtime, second_runtime, third_runtime ]),
      cursor: first.next_cursor,
      limit: 2
    )

    expect(first.entries.map(&:message)).to eq([ "first runtime line", "second runtime line" ])
    expect(first.next_cursor).to be_present
    expect(second.entries.map(&:message)).to eq([ "third runtime line" ])
    expect(second.next_cursor).not_to eq(first.next_cursor)
  end

  it "includes safe failure and Build lifecycle entries" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-failure")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "log-failure-build",
      expected_lock_version: deployment.lock_version
    ).build
    Builds::Fail.call(
      build:,
      retryable: false,
      error: {
        "phase" => "build",
        "code" => "compile_failed",
        "message" => "The sample did not compile"
      }
    )

    feed = described_class.call(
      deployment: deployment.reload,
      provider_result: provider_result(entries: [], status: :unavailable),
      limit: 100
    )

    expect(feed.provider_status).to eq(:unavailable)
    expect(feed.entries).to include(
      have_attributes(stream: "build", message: "Build attempt 1 started."),
      have_attributes(stream: "build", message: "Build attempt 1 failed."),
      have_attributes(stream: "system", level: "error", message: "The sample did not compile")
    )
  end

  it "renders the controller's bounded redacted Build log tail" do
    context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-build-tail")
    deployment = advance_deployment(deployment, to: :queued, actor: context.principal)
    deployment = advance_deployment(deployment, to: :preparing)
    build = Builds::Start.call(
      deployment:,
      idempotency_key: "log-build-tail",
      expected_lock_version: deployment.lock_version
    ).build
    build.update!(
      evidence: {
        "log_tail" => [
          "2026-07-12T12:00:00Z clone exact commit",
          "2026-07-12T12:00:01Z build image"
        ]
      }
    )

    feed = described_class.call(
      deployment: deployment.reload,
      provider_result: provider_result(entries: [], status: :not_found),
      limit: 100
    )

    expect(feed.entries).to include(
      have_attributes(stream: "build", message: "clone exact commit"),
      have_attributes(stream: "build", message: "build image")
    )
  end

  it "keeps persisted history visible beside a full runtime tail" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-history")
    runtime_entries = 120.times.map do |index|
      runtime_entry(
        timestamp: (Time.current + index.seconds).iso8601(6),
        message: "runtime line #{index}"
      )
    end

    feed = described_class.call(
      deployment:,
      provider_result: provider_result(entries: runtime_entries, truncated: true),
      limit: 100,
      include_history: true
    )

    expect(feed.entries.length).to eq(100)
    expect(feed.entries).to include(
      have_attributes(stream: "system", message: "Deployment request accepted."),
      have_attributes(stream: "runtime", message: "runtime line 119")
    )
  end

  it "preserves repeated runtime lines that share one timestamp" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-repeated")
    timestamp = Time.current.iso8601(6)
    repeated = 2.times.map { runtime_entry(timestamp:, message: "repeated line") }

    feed = described_class.call(
      deployment:,
      provider_result: provider_result(entries: repeated),
      limit: 100
    )

    expect(feed.entries.count { |entry| entry.message == "repeated line" }).to eq(2)
    expect(feed.entries.filter_map { |entry| entry.identity if entry.message == "repeated line" }.uniq.length).to eq(2)
  end

  it "rejects malformed cursors and out-of-range limits" do
    _context, _project, _environment, _service, deployment = create_deployment_domain(sequence: "log-invalid")
    result = provider_result(entries: [])

    expect do
      described_class.call(deployment:, provider_result: result, cursor: "invalid", limit: 25)
    end.to raise_error(described_class::InvalidCursor)
    expect do
      described_class.call(deployment:, provider_result: result, limit: 101)
    end.to raise_error(ArgumentError)
  end
end
