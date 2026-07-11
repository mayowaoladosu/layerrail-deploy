class Deployment < ApplicationRecord
  STATUSES = %w[
    created queued preparing building scanning deploying verifying ready promoted
    superseded canceling canceled failed
  ].index_with(&:itself).freeze
  CONCLUSIONS = %w[succeeded failed canceled].index_with(&:itself).freeze
  TRIGGERS = %w[manual webhook redeploy rollback].index_with(&:itself).freeze

  belongs_to :organization
  belongs_to :project
  belongs_to :service
  belongs_to :environment
  belongs_to :configuration_snapshot
  has_many :deployment_transitions, dependent: :restrict_with_exception

  enum :status, STATUSES, prefix: true, validate: true
  enum :conclusion, CONCLUSIONS, prefix: true, validate: { allow_nil: true }
  enum :trigger, TRIGGERS, prefix: true, validate: true

  attr_readonly :organization_id,
    :project_id,
    :service_id,
    :environment_id,
    :configuration_snapshot_id,
    :source_snapshot,
    :source_digest,
    :runtime_policy_snapshot,
    :build_settings_snapshot,
    :idempotency_key,
    :correlation_id,
    :trigger

  validates :idempotency_key, presence: true, length: { maximum: 255 }, uniqueness: { scope: :organization_id }
  validates :correlation_id, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/ }, uniqueness: true
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :snapshot_objects_are_bounded
  validate :ownership_matches

  def terminal?
    status.in?(%w[superseded canceled failed])
  end

  private

  def snapshot_objects_are_bounded
    {
      source_snapshot: 32.kilobytes,
      runtime_policy_snapshot: 16.kilobytes,
      build_settings_snapshot: 16.kilobytes
    }.each do |attribute, limit|
      value = public_send(attribute)
      errors.add(attribute, "must be an object") unless value.is_a?(Hash)
      errors.add(attribute, "is too large") if value.to_json.bytesize > limit
    end
  end

  def ownership_matches
    return unless organization && project && service && environment && configuration_snapshot

    unless project.organization_id == organization_id &&
        service.project_id == project_id &&
        environment.project_id == project_id &&
        configuration_snapshot.organization_id == organization_id &&
        configuration_snapshot.service_id == service_id &&
        configuration_snapshot.environment_id == environment_id
      errors.add(:organization, "must own all deployment resources")
    end
  end
end
