class EventReceipt < ApplicationRecord
  STATUSES = %w[processing completed].index_with(&:itself).freeze

  belongs_to :organization

  enum :status, STATUSES, validate: true

  attr_readonly :organization_id,
    :consumer,
    :event_id,
    :event_type,
    :payload_digest

  before_update :allow_completion_only
  before_destroy :prevent_mutation

  validates :consumer,
    presence: true,
    length: { maximum: 120 },
    format: { with: Events::Envelope::PRODUCER_PATTERN },
    uniqueness: { scope: :event_id }
  validates :event_id, format: { with: Events::Envelope::UUID_PATTERN }
  validates :event_type, format: { with: Events::Envelope::EVENT_TYPE_PATTERN }, length: { maximum: 255 }
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :result_is_bounded
  validate :lifecycle_is_consistent

  def inspect
    "#<#{self.class.name} id=#{id.inspect} consumer=#{consumer.inspect} status=#{status.inspect} result=[REDACTED]>"
  end

  private

  def allow_completion_only
    allowed = status_in_database == "processing" &&
      status == "completed" &&
      (changes.keys - %w[status result consumed_at updated_at]).empty?
    return if allowed

    errors.add(:base, "Event receipts are immutable after consumption")
    throw :abort
  end

  def prevent_mutation
    errors.add(:base, "Event receipts are append-only")
    throw :abort
  end

  def result_is_bounded
    unless result.is_a?(Hash)
      errors.add(:result, "must be an object")
      return
    end

    errors.add(:result, "is too large") if result.to_json.bytesize > 64.kilobytes
  end

  def lifecycle_is_consistent
    if status == "processing"
      errors.add(:consumed_at, "must be absent while processing") if consumed_at
    elsif status == "completed"
      errors.add(:consumed_at, "must be present after consumption") unless consumed_at
    end
  end
end
