class GitWebhookInbox < ApplicationRecord
  PROVIDERS = { github: "github" }.freeze
  STATUSES = {
    pending: "pending",
    processed: "processed",
    failed: "failed"
  }.freeze

  belongs_to :organization
  belongs_to :git_installation
  belongs_to :deployment, optional: true

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

  before_update :protect_terminal_outcome
  before_destroy :prevent_destruction

  validates :delivery_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :provider }
  validates :event_type, presence: true, length: { maximum: 120 }
  validates :provider_repository_id, length: { maximum: 255 }, allow_nil: true
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :safe_error, length: { maximum: 1000 }, allow_nil: true
  validate :data_is_a_bounded_object
  validate :processing_outcome_is_consistent

  private

  def protect_terminal_outcome
    return unless status_in_database.in?(%w[processed failed])
    return if (changes.keys & %w[status deployment_id safe_error processed_at]).empty?

    errors.add(:base, "Processed webhook outcomes are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Webhook inbox messages are append-only")
    throw :abort
  end

  def data_is_a_bounded_object
    unless data.is_a?(Hash)
      errors.add(:data, "must be an object")
      return
    end

    errors.add(:data, "is too large") if data.to_json.bytesize > 64.kilobytes
  end

  def processing_outcome_is_consistent
    case status
    when "pending"
      errors.add(:base, "Pending webhooks cannot have an outcome") if processed_at || deployment_id || safe_error
    when "processed"
      errors.add(:processed_at, "must be present") unless processed_at
      errors.add(:safe_error, "must be absent") if safe_error
    when "failed"
      errors.add(:processed_at, "must be present") unless processed_at
      errors.add(:deployment, "must be absent") if deployment_id
      errors.add(:safe_error, "must be present") if safe_error.blank?
    end
  end
end
