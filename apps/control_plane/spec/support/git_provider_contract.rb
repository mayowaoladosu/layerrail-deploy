RSpec.shared_examples "a Git provider adapter" do
  let(:clock_time) { Time.zone.parse("2026-07-11 20:00:00 UTC") }
  let(:installation_id) { "installation-1" }
  let(:repository_id) { "repository-1" }

  it "builds an installation flow without consuming its opaque state" do
    result = provider.installation_setup(
      state: "opaque-state-123",
      redirect_uri: "https://control.example.test/git/callback"
    )

    expect(result).to be_success
    expect(result.value.state).to eq("opaque-state-123")
    expect(result.value.url).to be_a(URI::HTTPS)
  end

  it "returns provider-neutral installation metadata" do
    result = provider.installation(id: installation_id)

    expect(result).to be_success
    expect(result.value).to have_attributes(
      id: installation_id,
      account_id: "account-1",
      account_login: "layerrail",
      account_type: "organization",
      status: "active"
    )
    expect(result.value.permissions).to eq("contents" => "read", "metadata" => "read")
  end

  it "returns explicit safe failures instead of provider exceptions" do
    result = provider.installation(id: "unknown-installation")

    expect(result).to be_failure
    expect(result.error).to have_attributes(
      code: :installation_not_found,
      message: "Installation was not found",
      retryable: false
    )
  end

  it "lists only installation-authorized repositories with opaque pagination" do
    session = provider.open_session(installation_id:).value

    first = session.repositories(limit: 1)
    second = session.repositories(limit: 1, cursor: first.value.next_cursor)

    expect(first).to be_success
    expect(first.value.items.map(&:id)).to eq([ "repository-1" ])
    expect(first.value.next_cursor).to be_present
    expect(second.value.items.map(&:id)).to eq([ "repository-2" ])
    expect(second.value.next_cursor).to be_nil
    expect(first.value.items).not_to include(unauthorized_repository)
  end

  it "rejects malformed or cross-operation pagination cursors" do
    session = provider.open_session(installation_id:).value
    repository_cursor = session.repositories(limit: 1).value.next_cursor

    malformed = session.repositories(limit: 1, cursor: "tampered")
    wrong_operation = session.branches(
      repository_id:,
      limit: 1,
      cursor: repository_cursor
    )

    expect(malformed).to be_failure
    expect(malformed.error.code).to eq(:invalid_cursor)
    expect(wrong_operation).to be_failure
    expect(wrong_operation.error.code).to eq(:invalid_cursor)
  end

  it "enforces bounded page sizes and immutable repository snapshots" do
    session = provider.open_session(installation_id:).value

    empty_limit = session.repositories(limit: 0)
    excessive_limit = session.repositories(limit: 101)
    repository = session.repositories(limit: 1).value.items.first

    expect(empty_limit).to be_failure
    expect(empty_limit.error.code).to eq(:invalid_request)
    expect(excessive_limit).to be_failure
    expect(excessive_limit.error.code).to eq(:invalid_request)
    expect(repository).to be_frozen
    expect(repository.full_name).to be_frozen
  end

  it "lists branches and commits only for authorized repositories" do
    session = provider.open_session(installation_id:).value

    branches = session.branches(repository_id:, limit: 10)
    commits = session.commits(repository_id:, ref: "main", limit: 10)
    unauthorized = session.branches(repository_id: unauthorized_repository.id, limit: 10)

    expect(branches.value.items.map(&:name)).to eq(%w[develop main])
    expect(commits.value.items.map(&:sha)).to eq(%w[bbbbbbbb aaaaaaaa])
    expect(unauthorized).to be_failure
    expect(unauthorized.error.code).to eq(:repository_not_found)
  end

  it "issues short-lived credentials without serializing or inspecting the secret" do
    session = provider.open_session(installation_id:).value

    result = session.clone_credentials(
      repository_id:,
      revision: "bbbbbbbb"
    )
    credentials = result.value

    expect(result).to be_success
    expect(credentials.expires_at).to eq(clock_time + 15.minutes)
    expect(credentials.secret).to be_present
    expect(credentials.to_h).to eq(
      clone_url: URI("https://git.example.test/layerrail/api.git"),
      username: "x-access-token",
      expires_at: clock_time + 15.minutes
    )
    expect(credentials.inspect).not_to include(credentials.secret)
  end

  it "does not issue credentials for unknown revisions" do
    session = provider.open_session(installation_id:).value

    result = session.clone_credentials(
      repository_id:,
      revision: "unknown-revision"
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:revision_not_found)
  end

  it "does not issue credentials for repositories outside the installation" do
    session = provider.open_session(installation_id:).value

    result = session.clone_credentials(
      repository_id: unauthorized_repository.id,
      revision: "bbbbbbbb"
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:repository_not_found)
  end

  it "maps provider users without returning or logging the access credential" do
    result = provider.map_user(access_token: "user-access-secret")

    expect(result).to be_success
    expect(result.value).to have_attributes(
      id: "provider-user-1",
      login: "mayowa",
      name: "Mayowa",
      email: "mayowa@example.test"
    )
    expect(provider.inspect).not_to include("user-access-secret")
  end

  it "returns a safe failure for an unknown provider user credential" do
    result = provider.map_user(access_token: "unknown-user-secret")

    expect(result).to be_failure
    expect(result.error.code).to eq(:user_not_found)
    expect(result.error.message).not_to include("unknown-user-secret")
  end

  it "verifies and normalizes a push webhook in one operation" do
    body = JSON.generate(
      installation: { id: installation_id },
      repository: { id: repository_id },
      ref: "refs/heads/main",
      before: "aaaaaaaa",
      after: "bbbbbbbb",
      pusher: { id: "provider-user-1" }
    )
    signature = webhook_signature(body)

    result = provider.verify_webhook(
      delivery_id: "delivery-1",
      event_type: "push",
      signature:,
      body:
    )

    expect(result).to be_success
    expect(result.value).to have_attributes(
      delivery_id: "delivery-1",
      type: "git.push.v1",
      installation_id:,
      repository_id:,
      occurred_at: clock_time
    )
    expect(result.value.data).to eq(
      "ref" => "main",
      "before_sha" => "aaaaaaaa",
      "after_sha" => "bbbbbbbb",
      "provider_user_id" => "provider-user-1"
    )
    expect(result.value.to_h.to_s).not_to include(body)
  end

  it "rejects an invalid webhook signature without parsing provider data" do
    body = JSON.generate(secret: "must-not-leak")

    result = provider.verify_webhook(
      delivery_id: "delivery-invalid",
      event_type: "push",
      signature: "sha256=invalid",
      body:
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:invalid_signature)
    expect(result.error.message).not_to include("must-not-leak")
  end

  it "rejects malformed and unsupported verified webhook payloads explicitly" do
    malformed_body = "not-json"
    unsupported_body = JSON.generate(action: "changed")

    malformed = provider.verify_webhook(
      delivery_id: "delivery-malformed",
      event_type: "push",
      signature: webhook_signature(malformed_body),
      body: malformed_body
    )
    unsupported = provider.verify_webhook(
      delivery_id: "delivery-unsupported",
      event_type: "issues",
      signature: webhook_signature(unsupported_body),
      body: unsupported_body
    )

    expect(malformed).to be_failure
    expect(malformed.error.code).to eq(:invalid_payload)
    expect(unsupported).to be_failure
    expect(unsupported.error.code).to eq(:unsupported_event)
  end

  it "normalizes installation disconnection events" do
    body = JSON.generate(
      action: "deleted",
      installation: { id: installation_id, account: { id: "account-1", login: "layerrail" } }
    )

    result = provider.verify_webhook(
      delivery_id: "delivery-installation",
      event_type: "installation",
      signature: webhook_signature(body),
      body:
    )

    expect(result).to be_success
    expect(result.value.type).to eq("git.installation.disconnected.v1")
  end

  it "normalizes pull request events without retaining the raw payload" do
    body = JSON.generate(
      action: "synchronize",
      installation: { id: installation_id },
      repository: { id: repository_id },
      number: 42,
      pull_request: {
        head: { ref: "feature", sha: "cccccccc" },
        base: { ref: "main" },
        merged: false
      },
      sender: { id: "provider-user-1" }
    )

    result = provider.verify_webhook(
      delivery_id: "delivery-pull-request",
      event_type: "pull_request",
      signature: webhook_signature(body),
      body:
    )

    expect(result).to be_success
    expect(result.value.type).to eq("git.pull_request.v1")
    expect(result.value.data).to include(
      "action" => "synchronize",
      "number" => 42,
      "head_ref" => "feature",
      "head_sha" => "cccccccc",
      "base_ref" => "main",
      "merged" => false
    )
    expect(result.value.to_h.to_s).not_to include(body)
  end

  it "disconnects installations idempotently and invalidates existing sessions" do
    session = provider.open_session(installation_id:).value

    first = provider.disconnect(installation_id:)
    second = provider.disconnect(installation_id:)
    repositories = session.repositories(limit: 10)

    expect(first).to be_success
    expect(second).to be_success
    expect(first.value.status).to eq("disconnected")
    expect(second.value).to eq(first.value)
    expect(repositories).to be_failure
    expect(repositories.error.code).to eq(:installation_inactive)
  end

  it "is deterministic for identical fixtures and clock input" do
    first_provider = build_provider
    second_provider = build_provider

    first = first_provider.open_session(installation_id:).value.clone_credentials(
      repository_id:,
      revision: "bbbbbbbb"
    ).value
    second = second_provider.open_session(installation_id:).value.clone_credentials(
      repository_id:,
      revision: "bbbbbbbb"
    ).value

    expect(first.to_h).to eq(second.to_h)
    expect(first.secret).to eq(second.secret)
  end
end
