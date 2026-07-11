class DeploymentTransition < ApplicationRecord
  belongs_to :deployment

  attr_readonly :deployment_id,
    :sequence,
    :from_status,
    :to_status,
    :actor_type,
    :actor_id,
    :cause,
    :error,
    :occurred_at

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :deployment_id }
  validates :to_status, inclusion: { in: Deployment::STATUSES.keys }
  validates :from_status, inclusion: { in: Deployment::STATUSES.keys }, allow_nil: true
  validates :actor_type, inclusion: { in: %w[user system] }
  validates :cause, presence: true, length: { maximum: 120 }
  validate :error_is_safe_and_bounded

  private

  def prevent_mutation
    errors.add(:base, "Deployment transitions are append-only")
    throw :abort
  end

  def error_is_safe_and_bounded
    return if error.blank?
    unless error.is_a?(Hash) && (error.keys - %w[phase code message diagnostic_reference]).empty?
      errors.add(:error, "must be structured")
      return
    end

    errors.add(:error, "is too large") if error.to_json.bytesize > 8.kilobytes
  end
end
