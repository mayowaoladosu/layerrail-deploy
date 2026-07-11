class OutboxEvent < ApplicationRecord
  STATUSES = %w[pending delivering published dead].index_with(&:itself).freeze
  UUID_PATTERN = Events::Envelope::UUID_PATTERN
  EVENT_TYPE_PATTERN = Events::Envelope::EVENT_TYPE_PATTERN
  PRODUCER_PATTERN = Events::Envelope::PRODUCER_PATTERN

  belongs_to :organization

  enum :status, STATUSES, validate: true

  attr_readonly :organization_id,
    :resource_id,
    :event_type,
    :correlation_id,
    :idempotency_key,
    :producer,
    :schema_version,
    :data,
    :data_digest,
    :occurred_at

  before_update :protect_delivery_transition
  before_destroy :prevent_destruction

  validates :resource_id, :correlation_id, format: { with: UUID_PATTERN }
  validates :event_type, format: { with: EVENT_TYPE_PATTERN }, length: { maximum: 255 }
  validates :idempotency_key,
    presence: true,
    length: { maximum: 255 },
    uniqueness: { scope: [ :organization_id, :producer ] }
  validates :producer, format: { with: PRODUCER_PATTERN }, length: { maximum: 63 }
  validates :schema_version, inclusion: { in: [ 1 ] }
  validates :data_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :available_at, presence: true
  validates :last_error, length: { maximum: 1000 }, allow_nil: true
  validate :data_is_bounded
  validate :idempotency_key_is_normalized
  validate :delivery_state_is_consistent

  def envelope
    Events::Envelope.build(
      event_id: id,
      event_type:,
      occurred_at:,
      organization_id:,
      resource_id:,
      correlation_id:,
      idempotency_key:,
      producer:,
      schema_version:,
      data:
    ).to_h
  end

  def inspect
    "#<#{self.class.name} id=#{id.inspect} event_type=#{event_type.inspect} status=#{status.inspect} data=[REDACTED]>"
  end

  private

  def protect_delivery_transition
    if status_in_database.in?(%w[published dead])
      errors.add(:base, "Terminal outbox delivery state is immutable")
      throw :abort
    end
    return unless will_save_change_to_status?
    return if {
      "pending" => %w[delivering],
      "delivering" => %w[pending published dead]
    }.fetch(status_in_database, []).include?(status)

    errors.add(:status, "transition is not allowed")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Outbox events are append-only")
    throw :abort
  end

  def data_is_bounded
    unless data.is_a?(Hash)
      errors.add(:data, "must be an object")
      return
    end

    errors.add(:data, "is too large") if data.to_json.bytesize > Events::Envelope::MAX_DATA_BYTES
  end

  def idempotency_key_is_normalized
    errors.add(:idempotency_key, "must be normalized") unless idempotency_key == idempotency_key.to_s.strip
  end

  def delivery_state_is_consistent
    case status
    when "pending"
      errors.add(:base, "Pending delivery cannot be claimed or published") if claim_token || locked_until || published_at
    when "delivering"
      errors.add(:base, "Delivering event requires a lease") unless claim_token && locked_until && !published_at
    when "published"
      errors.add(:base, "Published event requires a timestamp") unless published_at && !claim_token && !locked_until
    when "dead"
      errors.add(:base, "Dead event cannot be claimed or published") if claim_token || locked_until || published_at
    end
  end
end
