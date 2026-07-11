class Build < ApplicationRecord
  STATUSES = %w[running succeeded failed canceled].index_with(&:itself).freeze

  belongs_to :organization
  belongs_to :deployment
  has_one :revision, dependent: :restrict_with_exception

  enum :status, STATUSES, prefix: true, validate: true

  attr_readonly :organization_id,
    :deployment_id,
    :attempt,
    :idempotency_key,
    :started_at

  before_update :protect_terminal_state

  validates :attempt, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :deployment_id }
  validates :idempotency_key, presence: true, length: { maximum: 255 }, uniqueness: { scope: :deployment_id }
  validates :artifact_digest, format: { with: /\Asha256:[0-9a-f]{64}\z/ }, allow_nil: true
  validate :evidence_is_bounded
  validate :idempotency_key_is_normalized
  validate :organization_matches

  private

  def protect_terminal_state
    return unless status_in_database.in?(%w[succeeded failed canceled])
    return if (changes.keys & %w[status artifact_digest evidence finished_at]).empty?

    errors.add(:base, "Terminal build state is immutable")
    throw :abort
  end

  def evidence_is_bounded
    unless evidence.is_a?(Hash)
      errors.add(:evidence, "must be an object")
      return
    end

    errors.add(:evidence, "is too large") if evidence.to_json.bytesize > 32.kilobytes
  end

  def idempotency_key_is_normalized
    errors.add(:idempotency_key, "must be normalized") unless idempotency_key == idempotency_key.to_s.strip
  end

  def organization_matches
    return unless organization && deployment

    errors.add(:organization, "must own the deployment") unless deployment.organization_id == organization_id
  end
end
