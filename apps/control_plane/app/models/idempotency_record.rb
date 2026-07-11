class IdempotencyRecord < ApplicationRecord
  belongs_to :organization

  attr_readonly :organization_id,
    :key,
    :operation,
    :request_fingerprint,
    :response_status,
    :response_body,
    :resource_type,
    :resource_id

  validates :key, presence: true, length: { maximum: 255 }, uniqueness: { scope: :organization_id }
  validates :operation, presence: true, length: { maximum: 120 }
  validates :request_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :response_status, inclusion: { in: 200..599 }
  validate :response_body_is_an_object

  private

  def response_body_is_an_object
    errors.add(:response_body, "must be an object") unless response_body.is_a?(Hash)
  end
end
