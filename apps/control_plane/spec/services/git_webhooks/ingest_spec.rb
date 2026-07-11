require "rails_helper"

RSpec.describe GitWebhooks::Ingest do
  def setup_installation
    owner = User.create!(email: "webhook-owner@example.com", name: "Webhook Owner")
    organization = Organizations::Create.call(principal: owner, name: "Webhook Organization").organization
    context = AuthorizationContext.build(principal: owner, organization:)
    provider = build_fake_git_provider
    installation = GitInstallations::Connect.call(
      context:,
      provider:,
      provider_name: :github,
      provider_installation_id: "installation-1"
    ).value

    [ organization, context, provider, installation ]
  end

  def push_body(after_sha: "bbbbbbbb", installation_id: "installation-1")
    JSON.generate(
      installation: { id: installation_id },
      repository: { id: "repository-1" },
      ref: "refs/heads/main",
      before: "aaaaaaaa",
      after: after_sha,
      pusher: { id: "provider-user-1" },
      secret: "raw-payload-must-not-persist"
    )
  end

  def signature(body)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}"
  end

  it "persists one normalized organization-owned inbox message without raw payload" do
    organization, _context, provider, installation = setup_installation
    body = push_body

    result = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-1",
      event_type: "push",
      signature: signature(body),
      body:
    )

    expect(result).to be_success
    expect(result.value).to have_attributes(replayed: false, ignored: false)
    expect(result.value.message).to have_attributes(
      organization:,
      git_installation: installation,
      provider: "github",
      delivery_id: "delivery-1",
      event_type: "git.push.v1",
      provider_repository_id: "repository-1",
      status: "pending"
    )
    expect(result.value.message.data).to include("after_sha" => "bbbbbbbb")
    expect(result.value.message.payload_digest).to eq(Digest::SHA256.hexdigest(body))
    expect(result.value.message.attributes.to_s).not_to include("raw-payload-must-not-persist")
  end

  it "replays an identical delivery without creating a duplicate" do
    _organization, _context, provider, = setup_installation
    body = push_body

    first = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-replay",
      event_type: "push",
      signature: signature(body),
      body:
    )
    second = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-replay",
      event_type: "push",
      signature: signature(body),
      body:
    )

    expect(second).to be_success
    expect(second.value.replayed).to be(true)
    expect(second.value.message).to eq(first.value.message)
    expect(GitWebhookInbox.where(provider: :github, delivery_id: "delivery-replay").count).to eq(1)
  end

  it "rejects an altered replay without replacing the original" do
    _organization, _context, provider, = setup_installation
    original = push_body
    altered = push_body(after_sha: "cccccccc")
    described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-conflict",
      event_type: "push",
      signature: signature(original),
      body: original
    )

    result = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-conflict",
      event_type: "push",
      signature: signature(altered),
      body: altered
    )

    expect(result).to be_failure
    expect(result.error.code).to eq(:delivery_conflict)
    expect(GitWebhookInbox.find_by!(delivery_id: "delivery-conflict").data.fetch("after_sha")).to eq("bbbbbbbb")
  end

  it "does not persist invalid signatures or unknown installations" do
    _organization, _context, provider, = setup_installation
    known_body = push_body
    unknown_body = push_body(installation_id: "unknown-installation")

    invalid = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-invalid",
      event_type: "push",
      signature: "sha256=invalid",
      body: known_body
    )
    unknown = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-unknown",
      event_type: "push",
      signature: signature(unknown_body),
      body: unknown_body
    )

    expect(invalid).to be_failure
    expect(invalid.error.code).to eq(:invalid_signature)
    expect(unknown).to be_success
    expect(unknown.value.ignored).to be(true)
    expect(GitWebhookInbox).not_to exist
  end

  it "updates installation and repository metadata within the inbox transaction" do
    organization, context, provider, installation = setup_installation
    project = Projects::Create.call(context:, name: "Webhook Project", slug: "webhook-project").project
    service = Services::Create.call(
      context:,
      project:,
      name: "API",
      workload_type: :web,
      source_type: :git,
      source_reference: "pending"
    ).service
    connection = RepositoryConnections::Connect.call(
      context:,
      provider:,
      installation:,
      service:,
      provider_repository_id: "repository-1"
    ).value
    body = JSON.generate(
      action: "removed",
      installation: { id: "installation-1" },
      repositories_removed: [ { id: "repository-1" } ]
    )

    result = described_class.call(
      provider:,
      provider_name: :github,
      delivery_id: "delivery-removed",
      event_type: "installation_repositories",
      signature: signature(body),
      body:
    )

    expect(result.value.message).to have_attributes(organization:, status: "processed")
    expect(connection.reload.status).to eq("removed")
  end
end
