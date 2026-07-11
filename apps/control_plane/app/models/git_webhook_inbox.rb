class GitWebhookInbox < ApplicationRecord
  PROVIDERS = { github: "github" }.freeze
  STATUSES = {
    pending: "pending",
    processed: "processed",
    failed: "failed"
  }.freeze

  belongs_to :organization
  belongs_to :git_installation

  enum :provider, PROVIDERS, validate: true
  enum :status, STATUSES, validate: true

  attr_readonly :organization_id,
    :git_installation_id,
    :provider,
    :delivery_id,
    :event_type,
    :provider_repository_id,
    :occurred_at,
    :payload_digest,
    :data

  validates :delivery_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :provider }
  validates :event_type, presence: true, length: { maximum: 120 }
  validates :provider_repository_id, length: { maximum: 255 }, allow_nil: true
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :data_is_a_bounded_object

  private

  def data_is_a_bounded_object
    unless data.is_a?(Hash)
      errors.add(:data, "must be an object")
      return
    end

    errors.add(:data, "is too large") if data.to_json.bytesize > 64.kilobytes
  end
end
