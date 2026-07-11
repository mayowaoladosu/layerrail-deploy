class ConfigurationVersion < ApplicationRecord
  belongs_to :organization
  belongs_to :project
  belongs_to :environment
  belongs_to :service, optional: true
  belongs_to :created_by, class_name: "User"
  has_many :project_configuration_snapshots,
    class_name: "ConfigurationSnapshot",
    foreign_key: :project_configuration_version_id,
    dependent: :restrict_with_exception,
    inverse_of: :project_configuration_version
  has_many :service_configuration_snapshots,
    class_name: "ConfigurationSnapshot",
    foreign_key: :service_configuration_version_id,
    dependent: :restrict_with_exception,
    inverse_of: :service_configuration_version

  encrypts :payload_json

  attr_readonly :organization_id,
    :project_id,
    :environment_id,
    :service_id,
    :created_by_id,
    :scope_key,
    :version,
    :key_summary,
    :payload_json,
    :payload_digest

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  validates :scope_key, presence: true, length: { maximum: 255 }
  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: [ :environment_id, :scope_key ] }
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :ownership_matches
  validate :key_summary_is_bounded

  def self.build_encrypted(attributes, payload_json:)
    new(attributes).tap { |record| record.send(:payload_json=, payload_json) }
  end

  def as_json(*)
    super(
      only: [ :id, :organization_id, :project_id, :environment_id, :service_id, :scope_key, :version, :key_summary, :payload_digest, :created_at ]
    )
  end

  def inspect
    "#<#{self.class.name} id=#{id.inspect} scope_key=#{scope_key.inspect} version=#{version.inspect} keys=#{key_summary.inspect} payload=[REDACTED]>"
  end

  private

  def decrypted_variables
    JSON.parse(payload_json)
  end

  def prevent_mutation
    errors.add(:base, "Configuration versions are immutable")
    throw :abort
  end

  def ownership_matches
    return unless organization && project && environment

    unless project.organization_id == organization_id && environment.project_id == project_id
      errors.add(:organization, "must own the project and environment")
    end
    if service && service.project_id != project_id
      errors.add(:service, "must belong to the project")
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
