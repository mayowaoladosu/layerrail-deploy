class ConfigurationSnapshot < ApplicationRecord
  belongs_to :organization
  belongs_to :project
  belongs_to :environment
  belongs_to :service
  belongs_to :project_configuration_version,
    class_name: "ConfigurationVersion",
    optional: true,
    inverse_of: :project_configuration_snapshots
  belongs_to :service_configuration_version,
    class_name: "ConfigurationVersion",
    optional: true,
    inverse_of: :service_configuration_snapshots
  belongs_to :created_by, class_name: "User"
  has_many :deployments, dependent: :restrict_with_exception

  encrypts :payload_json

  attr_readonly :organization_id,
    :project_id,
    :environment_id,
    :service_id,
    :project_configuration_version_id,
    :service_configuration_version_id,
    :created_by_id,
    :key_summary,
    :payload_json,
    :payload_digest

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :ownership_matches
  validate :key_summary_is_bounded

  def self.build_encrypted(attributes, payload_json:)
    new(attributes).tap { |record| record.send(:payload_json=, payload_json) }
  end

  def as_json(*)
    super(
      only: [ :id, :organization_id, :project_id, :environment_id, :service_id, :key_summary, :payload_digest, :created_at ]
    )
  end

  def inspect
    "#<#{self.class.name} id=#{id.inspect} keys=#{key_summary.inspect} payload=[REDACTED]>"
  end

  private

  def decrypted_variables
    JSON.parse(payload_json)
  end

  def prevent_mutation
    errors.add(:base, "Configuration snapshots are immutable")
    throw :abort
  end

  def ownership_matches
    return unless organization && project && environment && service

    unless project.organization_id == organization_id &&
        environment.project_id == project_id &&
        service.project_id == project_id
      errors.add(:organization, "must own the project, environment, and service")
    end
    if project_configuration_version && project_configuration_version.scope_key != "project"
      errors.add(:project_configuration_version, "must use project scope")
    end
    if service_configuration_version && service_configuration_version.scope_key != "service:#{service_id}"
      errors.add(:service_configuration_version, "must use service scope")
    end
  end

  def key_summary_is_bounded
    unless key_summary.is_a?(Array) && key_summary.all? { |item| item.is_a?(Hash) }
      errors.add(:key_summary, "must be an array")
      return
    end

    errors.add(:key_summary, "is too large") if key_summary.to_json.bytesize > 32.kilobytes
  end
end
