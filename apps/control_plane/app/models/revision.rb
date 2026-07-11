class Revision < ApplicationRecord
  STATUSES = %w[candidate ready retired].index_with(&:itself).freeze

  belongs_to :organization
  belongs_to :project
  belongs_to :service
  belongs_to :environment
  belongs_to :deployment
  belongs_to :build
  belongs_to :configuration_snapshot

  enum :status, STATUSES, prefix: true, validate: true

  before_update :protect_readiness_evidence

  attr_readonly :organization_id,
    :project_id,
    :service_id,
    :environment_id,
    :deployment_id,
    :build_id,
    :configuration_snapshot_id,
    :artifact_digest,
    :runtime_policy_snapshot,
    :region,
    :cell

  validates :build_id, uniqueness: true
  validates :artifact_digest, format: { with: /\Asha256:[0-9a-f]{64}\z/ }
  validates :region, :cell, presence: true, length: { maximum: 64 }
  validate :ownership_matches
  validate :placement_is_normalized
  validate :snapshots_are_bounded
  validate :ready_state_is_consistent

  private

  def protect_readiness_evidence
    return unless status_in_database.in?(%w[ready retired])
    return if (changes.keys & %w[readiness ready_at]).empty?

    errors.add(:base, "Readiness evidence is immutable")
    throw :abort
  end

  def ownership_matches
    return unless organization && project && service && environment && deployment && build && configuration_snapshot

    unless project.organization_id == organization_id &&
        service.project_id == project_id &&
        environment.project_id == project_id &&
        deployment.organization_id == organization_id &&
        deployment.project_id == project_id &&
        deployment.service_id == service_id &&
        deployment.environment_id == environment_id &&
        build.deployment_id == deployment_id &&
        build.organization_id == organization_id &&
        build.artifact_digest == artifact_digest &&
        configuration_snapshot.id == deployment.configuration_snapshot_id &&
        configuration_snapshot.organization_id == organization_id &&
        configuration_snapshot.project_id == project_id &&
        configuration_snapshot.service_id == service_id &&
        configuration_snapshot.environment_id == environment_id
      errors.add(:organization, "must own all revision resources")
    end
  end

  def snapshots_are_bounded
    unless runtime_policy_snapshot.is_a?(Hash)
      errors.add(:runtime_policy_snapshot, "must be an object")
    else
      errors.add(:runtime_policy_snapshot, "is too large") if runtime_policy_snapshot.to_json.bytesize > 16.kilobytes
    end

    unless readiness.is_a?(Hash)
      errors.add(:readiness, "must be an object")
      return
    end

    errors.add(:readiness, "is too large") if readiness.to_json.bytesize > 16.kilobytes
  end

  def placement_is_normalized
    errors.add(:region, "must be normalized") unless region == region.to_s.strip
    errors.add(:cell, "must be normalized") unless cell == cell.to_s.strip
  end

  def ready_state_is_consistent
    if status.in?(%w[ready retired])
      errors.add(:ready_at, "must be present") unless ready_at
      errors.add(:readiness, "must record a passing check") unless readiness.is_a?(Hash) && readiness["status"] == "passed"
      errors.add(:build, "must have passing scan evidence") unless build&.evidence&.fetch("scan_status", nil) == "passed"
    elsif ready_at
      errors.add(:ready_at, "must be absent for a candidate")
    end
  end
end
