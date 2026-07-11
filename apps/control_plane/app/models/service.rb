class Service < ApplicationRecord
  WORKLOAD_TYPES = {
    static: "static",
    web: "web",
    private: "private",
    worker: "worker",
    cron: "cron",
    job: "job"
  }.freeze

  SOURCE_TYPES = {
    git: "git",
    oci: "oci"
  }.freeze

  RUNTIME_POLICY_KEYS = %w[
    readiness_path
    liveness_path
    graceful_shutdown_seconds
  ].freeze

  MAX_RUNTIME_POLICY_BYTES = 16.kilobytes

  belongs_to :project
  has_one :repository_connection, dependent: :restrict_with_exception

  delegate :organization, :organization_id, to: :project

  enum :workload_type, WORKLOAD_TYPES, prefix: true, validate: true
  enum :source_type, SOURCE_TYPES, prefix: true, validate: true
  enum :lifecycle_state, Project::LIFECYCLE_STATES, prefix: true, validate: true

  before_validation :normalize_attributes

  validates :name,
    presence: true,
    length: { maximum: 120 },
    uniqueness: { scope: :project_id, case_sensitive: false }
  validates :source_reference, presence: true, length: { maximum: 2048 }
  validate :runtime_policy_is_bounded

  private

  def normalize_attributes
    self.name = name.to_s.strip
    self.source_reference = source_reference.to_s.strip
    self.runtime_policy ||= {}
  end

  def runtime_policy_is_bounded
    unless runtime_policy.is_a?(Hash)
      errors.add(:runtime_policy, "must be an object")
      return
    end

    unknown_keys = runtime_policy.keys.map(&:to_s) - RUNTIME_POLICY_KEYS
    errors.add(:runtime_policy, "contains unsupported settings") if unknown_keys.any?
    errors.add(:runtime_policy, "is too large") if runtime_policy.to_json.bytesize > MAX_RUNTIME_POLICY_BYTES

    validate_path_setting("readiness_path")
    validate_path_setting("liveness_path")
    validate_shutdown_setting
  end

  def validate_path_setting(key)
    value = runtime_policy[key]
    return if value.nil?
    return if value.is_a?(String) && value.start_with?("/") && value.length <= 2048

    errors.add(:runtime_policy, "#{key} must be an absolute path")
  end

  def validate_shutdown_setting
    value = runtime_policy["graceful_shutdown_seconds"]
    return if value.nil?
    return if value.is_a?(Integer) && value.between?(1, 300)

    errors.add(:runtime_policy, "graceful_shutdown_seconds must be between 1 and 300")
  end
end
